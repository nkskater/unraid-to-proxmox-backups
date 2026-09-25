# shellcheck shell=bash
# Backup jobs: discovery, loading, validation and execution.
#
# A job is a bash file in $UPB_CONFIG_DIR/jobs.d/NN-name.conf naming one
# Unraid folder (EXPORT). Each job becomes one backup group on PBS
# (host/<BACKUP_ID_PREFIX>-<name>) whose snapshots hold one archive, <name>.pxar.

ARCHIVE_NAME_RE='^[A-Za-z0-9_-]+$'
BACKUP_ID_RE='^[A-Za-z0-9_][A-Za-z0-9._-]*$'

job_files() {
  local f
  for f in "$UPB_CONFIG_DIR"/jobs.d/*.conf; do
    [[ -f $f ]] && printf '%s\n' "$f"
  done
  return 0
}

# 10-appdata-backup.conf -> appdata-backup
job_name() {
  local base
  base=$(basename "$1" .conf)
  [[ $base =~ ^[0-9]+-(.+)$ ]] && base=${BASH_REMATCH[1]}
  printf '%s' "$base"
}

find_job_file() {
  local f
  while IFS= read -r f; do
    if [[ $(job_name "$f") == "$1" ]]; then
      printf '%s' "$f"
      return 0
    fi
  done < <(job_files)
  return 1
}

# Loads a job into the current shell. Call it in a subshell so jobs can't
# leak settings into each other.
# shellcheck disable=SC2034  # job settings are read by run_job and the commands
load_job() {
  JOB_ENABLED=true
  EXPORT=""
  EXCLUDES=()
  WAIT_FOR_QUIET=false
  ONLY_NEWEST=0
  BACKUP_ID=""

  JOB_NAME=$(job_name "$1")
  # shellcheck source=/dev/null
  if ! source "$1"; then
    error "[$JOB_NAME] failed to load $1"
    return 1
  fi
  BACKUP_ID=${BACKUP_ID:-${BACKUP_ID_PREFIX:+$BACKUP_ID_PREFIX-}$JOB_NAME}
  JOB_MOUNT="$MOUNT_ROOT/$JOB_NAME"
}

job_enabled() {
  (load_job "$1" >/dev/null 2>&1 && [[ $JOB_ENABLED == true ]])
}

# Prints the backup id of a job given its name.
job_backup_id() {
  local file
  file=$(find_job_file "$1") || {
    error "unknown job: $1 (see: upb list)"
    return 1
  }
  (load_job "$file" && printf '%s' "$BACKUP_ID")
}

validate_job() {
  local rc=0
  if [[ ! $JOB_NAME =~ $ARCHIVE_NAME_RE ]]; then
    error "[$JOB_NAME] job names (from the file name) may only contain letters, digits, '_' and '-'"
    rc=1
  fi
  if [[ ! $BACKUP_ID =~ $BACKUP_ID_RE ]]; then
    error "[$JOB_NAME] invalid BACKUP_ID '$BACKUP_ID'"
    rc=1
  fi
  if [[ $EXPORT != /?* ]]; then
    error "[$JOB_NAME] EXPORT must be the absolute Unraid path of the folder, e.g. /mnt/user/photos"
    rc=1
  fi
  case $WAIT_FOR_QUIET in
    true | false) ;;
    *)
      error "[$JOB_NAME] WAIT_FOR_QUIET must be true or false"
      rc=1
      ;;
  esac
  if [[ ! $ONLY_NEWEST =~ ^[0-9]+$ ]]; then
    error "[$JOB_NAME] ONLY_NEWEST must be a number (0 = back up everything)"
    rc=1
  fi
  return "$rc"
}

# Escapes glob characters so a file name matches only itself in an exclude pattern.
escape_pattern() {
  local s=$1 c out="" i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      '*' | '?' | '[' | ']' | \\) out+="\\$c" ;;
      *) out+=$c ;;
    esac
  done
  printf '%s' "$out"
}

# With ONLY_NEWEST=N, adds excludes for all but the N most recently modified
# top-level entries of the mounted export. For folders that collect one copy
# per run (Appdata Backup): PBS keeps the history, so only the newest run needs
# to be read.
exclude_older_entries() {
  local -a entries=()
  local count i
  if dry_run; then
    info "[$JOB_NAME] [dry-run] would back up only the newest $ONLY_NEWEST entries"
    return 0
  fi
  mapfile -d '' -t entries < <(find "$JOB_MOUNT" -mindepth 1 -maxdepth 1 -printf '%T@\t%f\0' |
    sort -z -n | cut -z -f2-)
  count=${#entries[@]}
  ((count > ONLY_NEWEST)) || return 0
  for ((i = 0; i < count - ONLY_NEWEST; i++)); do
    EXCLUDES+=("/$(escape_pattern "${entries[i]}")")
  done
  info "[$JOB_NAME] backing up the newest $ONLY_NEWEST of $count entries: ${entries[*]:count-ONLY_NEWEST}"
}

# Runs one job: mount the export read-only, optionally wait for writes to
# settle and skip older runs, back it up, unmount. Call it in its own subshell: it sources the job
# file and sets traps.
run_job() {
  local rc
  load_job "$1" || return 1
  validate_job || return 1

  trap 'unmount_export "$JOB_MOUNT"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  mount_export "$EXPORT" "$JOB_MOUNT" || return 1
  if [[ $WAIT_FOR_QUIET == true ]]; then
    wait_for_quiet "$JOB_MOUNT" || return 1
  fi
  if ((ONLY_NEWEST > 0)); then
    exclude_older_entries
  fi

  info "[$JOB_NAME] backing up $UNRAID_HOST:$EXPORT to host/$BACKUP_ID"
  pbs_backup "$BACKUP_ID" "$JOB_NAME.pxar:$JOB_MOUNT"
  rc=$?
  ((rc == 0)) || error "[$JOB_NAME] proxmox-backup-client failed (exit $rc)"
  unmount_export "$JOB_MOUNT"
  return "$rc"
}

# Mounts a job's export to prove it is reachable and non-empty. Call in a subshell.
check_job() {
  load_job "$1" || return 1
  validate_job || return 1
  trap 'unmount_export "$JOB_MOUNT"' EXIT
  mount_export "$EXPORT" "$JOB_MOUNT"
}
