# shellcheck shell=bash
# Offsite copies with restic, e.g. to Google Drive through rclone. restic
# encrypts everything before it leaves this machine, deduplicates, and keeps
# its own snapshots, so the copy doesn't depend on PBS at all.

RESTIC=""
RCLONE=""

offsite_uses_rclone() { [[ $OFFSITE_REPOSITORY == rclone:* ]]; }

ensure_restic() {
  if ! RESTIC=$(command -v "$RESTIC_CMD"); then
    error "$RESTIC_CMD not found (apt install restic)"
    return 1
  fi
  if offsite_uses_rclone && ! RCLONE=$(command -v "$RCLONE_CMD"); then
    error "$RCLONE_CMD not found (see docs/offsite.md)"
    return 1
  fi
}

# Runs restic against the offsite repository. The repository, the password
# file and the rclone config are passed through the environment; the password
# itself only ever lives in its file.
restic_run() {
  if dry_run; then
    info "[dry-run] restic $(quote_args "$@")"
    return 0
  fi
  local -a opts=()
  if offsite_uses_rclone; then opts+=(-o "rclone.program=$RCLONE"); fi
  (
    unset RESTIC_PASSWORD RESTIC_PASSWORD_COMMAND RESTIC_REPOSITORY_FILE
    export RESTIC_REPOSITORY=$OFFSITE_REPOSITORY
    export RESTIC_PASSWORD_FILE=$OFFSITE_PASSWORD_FILE
    if [[ -n $OFFSITE_PACK_SIZE ]]; then export RESTIC_PACK_SIZE=$OFFSITE_PACK_SIZE; fi
    if [[ -n $OFFSITE_CACHE_DIR ]]; then export RESTIC_CACHE_DIR=$OFFSITE_CACHE_DIR; fi
    if [[ -n $OFFSITE_RCLONE_CONFIG ]]; then export RCLONE_CONFIG=$OFFSITE_RCLONE_CONFIG; fi
    # upb's output goes through the log file, where restic shows no progress
    # unless asked to: a line a minute shows how far a long upload got.
    if [[ $1 == backup && -z ${RESTIC_PROGRESS_FPS:-} ]]; then export RESTIC_PROGRESS_FPS=0.0167; fi
    exec "$RESTIC" "${opts[@]}" "$@"
  )
}

# Turns an exclude pattern written for PBS into one for restic. Both use
# gitignore-style patterns, but a leading / anchors a PBS pattern at the share
# and a restic pattern at the filesystem root, so those get the mount point
# prepended.
restic_pattern() {
  local pattern=$1 root=$2
  if [[ $pattern == /* ]]; then
    printf '%s%s' "$(escape_pattern "$root")" "$pattern"
  else
    printf '%s' "$pattern"
  fi
}

# restic_backup <tag> <dir> — uses COMMON_EXCLUDES and the job's EXCLUDES.
restic_backup() {
  local tag=$1 dir=$2 pattern
  # --ignore-inode: Unraid's user shares can hand out new inode numbers, so
  # only size and modification time decide whether a file changed.
  local -a args=(backup --host "$OFFSITE_HOST" --tag "$tag" --ignore-inode)
  for pattern in "${COMMON_EXCLUDES[@]}" "${EXCLUDES[@]}"; do
    args+=(--exclude "$(restic_pattern "$pattern" "$dir")")
  done
  args+=("${OFFSITE_EXTRA_ARGS[@]}" "$dir")
  restic_run "${args[@]}"
}

# Applies the retention policy to each job's snapshots. On OFFSITE_PRUNE_WEEKDAY
# it also deletes the data no snapshot needs anymore, and on OFFSITE_CHECK_DAY
# it downloads a sample of the repository and verifies it.
offsite_maintenance() {
  local rc=0
  local -a args=(forget --host "$OFFSITE_HOST" --group-by "host,tags"
    --keep-daily "$OFFSITE_KEEP_DAILY" --keep-weekly "$OFFSITE_KEEP_WEEKLY"
    --keep-monthly "$OFFSITE_KEEP_MONTHLY")
  if [[ $(date +%u) == "$OFFSITE_PRUNE_WEEKDAY" ]]; then
    args+=(--prune)
  fi
  info "applying the offsite retention policy"
  if ! restic_run "${args[@]}"; then
    error "restic forget failed"
    rc=1
  fi
  if [[ $(date +%-d) == "$OFFSITE_CHECK_DAY" ]]; then
    info "verifying $OFFSITE_CHECK_SUBSET of the offsite repository"
    if ! restic_run check --read-data-subset="$OFFSITE_CHECK_SUBSET"; then
      error "restic check failed"
      rc=1
    fi
  fi
  return "$rc"
}
