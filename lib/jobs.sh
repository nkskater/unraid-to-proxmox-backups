# shellcheck shell=bash
# Backup jobs: discovery, loading, validation and execution.
#
# A job is a bash file in $UPB_CONFIG_DIR/jobs.d/NN-name.conf. Each job becomes
# one backup group on PBS (host/<BACKUP_ID_PREFIX>-<name>), and each entry in
# SOURCES becomes one archive inside that group's snapshots.

ARCHIVE_NAME_RE='^[A-Za-z0-9_-]+$'
BACKUP_ID_RE='^[A-Za-z0-9_][A-Za-z0-9._-]*$'

job_files() {
  local f
  for f in "$UPB_CONFIG_DIR"/jobs.d/*.conf; do
    [[ -f $f ]] && printf '%s\n' "$f"
  done
  return 0
}

# 30-appdata.conf -> appdata
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
# leak variables or hook functions into each other.
# shellcheck disable=SC2034  # job settings are read by run_job and the commands
load_job() {
  JOB_ENABLED=true
  JOB_DESCRIPTION=""
  BACKUP_ID=""
  SOURCES=()
  EXCLUDES=()
  STOP_CONTAINERS=()
  pre_backup() { :; }
  post_backup() { :; }

  JOB_NAME=$(job_name "$1")
  JOB_DUMP_DIR="$STAGING_DIR/$JOB_NAME"
  # shellcheck source=/dev/null
  if ! source "$1"; then
    error "[$JOB_NAME] failed to load $1"
    return 1
  fi
  BACKUP_ID=${BACKUP_ID:-${BACKUP_ID_PREFIX:+$BACKUP_ID_PREFIX-}$JOB_NAME}
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
  local spec name path rc=0
  local -A seen=()
  if [[ ! $JOB_NAME =~ $BACKUP_ID_RE ]]; then
    error "[$JOB_NAME] job file name may only contain letters, digits, '.', '_' and '-'"
    rc=1
  fi
  if [[ ! $BACKUP_ID =~ $BACKUP_ID_RE ]]; then
    error "[$JOB_NAME] invalid BACKUP_ID '$BACKUP_ID'"
    rc=1
  fi
  for spec in "${SOURCES[@]}"; do
    if [[ $spec != *:/* ]]; then
      error "[$JOB_NAME] source '$spec' must look like 'name:/absolute/path'"
      rc=1
      continue
    fi
    name=${spec%%:*}
    path=${spec#*:}
    if [[ ! $name =~ $ARCHIVE_NAME_RE ]]; then
      error "[$JOB_NAME] archive name '$name' may only contain letters, digits, '_' and '-'"
      rc=1
    elif [[ $name == dumps ]]; then
      error "[$JOB_NAME] archive name 'dumps' is reserved for database dumps"
      rc=1
    elif [[ -n ${seen[$name]:-} ]]; then
      error "[$JOB_NAME] archive name '$name' is used twice"
      rc=1
    fi
    seen[$name]=1
    if [[ ! -d $path ]]; then
      error "[$JOB_NAME] source directory does not exist: $path"
      rc=1
    fi
  done
  return "$rc"
}

# Runs one job: pre_backup hook, stop containers, back up, restart containers,
# post_backup hook.
#
# Must run in its own subshell (it sources the job file and sets traps), and
# must not be called from an if/&&/|| context, or bash ignores the `set -e`
# that makes a failing command inside a hook fail the hook.
run_job() {
  local rc hook_rc spec
  local -a specs=()
  load_job "$1" || return 1
  validate_job || return 1

  trap 'restart_stopped_containers' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if ! dry_run && ! mkdir -p "$JOB_DUMP_DIR"; then
    error "[$JOB_NAME] cannot create staging directory $JOB_DUMP_DIR"
    return 1
  fi

  (
    set -e
    pre_backup
  )
  hook_rc=$?
  if ((hook_rc != 0)); then
    error "[$JOB_NAME] pre_backup failed (exit $hook_rc), skipping backup"
    return "$hook_rc"
  fi

  for spec in "${SOURCES[@]}"; do
    specs+=("${spec%%:*}.pxar:${spec#*:}")
  done
  if [[ -d $JOB_DUMP_DIR && -n $(find "$JOB_DUMP_DIR" -mindepth 1 -print -quit) ]]; then
    specs+=("dumps.pxar:$JOB_DUMP_DIR")
  fi
  # From here on post_backup always runs, so hooks can undo what pre_backup did.
  if ((${#specs[@]} == 0)) && dry_run; then
    info "[$JOB_NAME] [dry-run] nothing to back up yet (no SOURCES; dumps are only written by a real run)"
    rc=0
  elif ((${#specs[@]} == 0)); then
    error "[$JOB_NAME] nothing to back up: no SOURCES and pre_backup wrote no dumps"
    rc=1
  elif ! stop_containers "${STOP_CONTAINERS[@]}"; then
    error "[$JOB_NAME] could not stop containers, skipping backup"
    rc=1
  else
    info "[$JOB_NAME] backing up ${#specs[@]} archive(s) to host/$BACKUP_ID"
    pbs_backup "$BACKUP_ID" "${specs[@]}"
    rc=$?
    ((rc == 0)) || error "[$JOB_NAME] proxmox-backup-client failed (exit $rc)"
  fi

  restart_stopped_containers || rc=1

  (
    set -e
    post_backup "$rc"
  )
  hook_rc=$?
  if ((hook_rc != 0)); then
    error "[$JOB_NAME] post_backup failed (exit $hook_rc)"
    ((rc == 0)) && rc=$hook_rc
  fi
  return "$rc"
}
