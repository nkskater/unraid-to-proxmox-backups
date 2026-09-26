# shellcheck shell=bash
# Shared helpers: logging, config loading and validation, locking.

UPB_CONFIG_DIR="${UPB_CONFIG_DIR:-/etc/upb}"
UPB_DRY_RUN="${UPB_DRY_RUN:-false}"
UPB_LOG_FILE=""

log() {
  local level=$1
  shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}
info() { log INFO "$@"; }
warn() { log WARN "$@" >&2; }
error() { log ERROR "$@" >&2; }
die() {
  error "$@"
  exit 1
}

dry_run() { [[ $UPB_DRY_RUN == true ]]; }

quote_args() {
  local out
  printf -v out '%q ' "$@"
  printf '%s' "${out% }"
}

format_duration() {
  local s=$1
  if ((s >= 3600)); then
    printf '%dh%02dm%02ds' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
  elif ((s >= 60)); then
    printf '%dm%02ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}

# Prints the contents of a secret file with all whitespace removed.
read_secret() {
  local secret
  if [[ ! -r $1 ]]; then
    error "cannot read secret file: $1"
    return 1
  fi
  secret=$(<"$1")
  secret=${secret//[[:space:]]/}
  if [[ -z $secret ]]; then
    error "secret file is empty: $1"
    return 1
  fi
  printf '%s' "$secret"
}

# Defaults for every setting in upb.conf. The config file overrides them.
# shellcheck disable=SC2034  # used by the other lib files
set_config_defaults() {
  UNRAID_HOST=""
  NFS_OPTIONS="ro,soft,timeo=600,retrans=2"
  MOUNT_ROOT="/mnt/upb"

  PBS_SERVER="localhost"
  PBS_PORT=8007
  PBS_DATASTORE=""
  PBS_NAMESPACE=""
  PBS_AUTH_ID=""
  PBS_TOKEN_FILE="$UPB_CONFIG_DIR/secrets/pbs-token"
  PBS_FINGERPRINT=""
  PBS_CLIENT_CMD="proxmox-backup-client"

  PBS_ENCRYPTION=false
  PBS_KEYFILE="$UPB_CONFIG_DIR/secrets/encryption.key"

  PBS_CHANGE_DETECTION_MODE=metadata
  PBS_EXTRA_ARGS=()
  COMMON_EXCLUDES=()
  BACKUP_ID_PREFIX="unraid"
  QUIET_MINUTES=10
  QUIET_TIMEOUT_MINUTES=180
  QUIET_POLL_SECONDS=60

  LOG_DIR="/var/log/upb"
  LOG_KEEP_DAYS=30
  LOCK_FILE="/run/upb.lock"
  NOTIFY_EMAIL=""
  NOTIFY_NTFY_URL=""
  NOTIFY_ON_SUCCESS=false
  SENDMAIL_CMD="sendmail"
  HEALTHCHECK_URL=""

  OFFSITE_ENABLED=false
  OFFSITE_REPOSITORY="rclone:gdrive:upb-offsite"
  OFFSITE_PASSWORD_FILE="$UPB_CONFIG_DIR/secrets/restic-password"
  OFFSITE_RCLONE_CONFIG="$UPB_CONFIG_DIR/secrets/rclone.conf"
  OFFSITE_MOUNT_ROOT="/mnt/upb-offsite"
  OFFSITE_HOST="upb"
  OFFSITE_KEEP_DAILY=7
  OFFSITE_KEEP_WEEKLY=4
  OFFSITE_KEEP_MONTHLY=6
  OFFSITE_PRUNE_WEEKDAY=7
  OFFSITE_CHECK_DAY=1
  OFFSITE_CHECK_SUBSET="5%"
  OFFSITE_PACK_SIZE=64
  OFFSITE_CACHE_DIR="/var/cache/upb/restic"
  OFFSITE_EXTRA_ARGS=()
  OFFSITE_LOCK_FILE="/run/upb-offsite.lock"
  OFFSITE_HEALTHCHECK_URL=""
  RESTIC_CMD="restic"
  RCLONE_CMD="rclone"
}

load_config() {
  local conf="$UPB_CONFIG_DIR/upb.conf"
  set_config_defaults
  if [[ ! -r $conf ]]; then
    die "config not found: $conf (run install.sh first, or set UPB_CONFIG_DIR)"
  fi
  # shellcheck source=/dev/null
  source "$conf" || die "failed to load $conf"
}

# The check_* functions each append to the caller's problems array, so every
# problem is reported at once.

# Settings for reading Unraid: needed by backups and offsite copies.
check_source_settings() {
  [[ -n $UNRAID_HOST ]] || problems+=("UNRAID_HOST is not set")
  # Read-only is not negotiable: this tool must never be able to change Unraid data.
  [[ ,$NFS_OPTIONS, == *,ro,* ]] || problems+=("NFS_OPTIONS must include 'ro' (got '$NFS_OPTIONS')")
  [[ $MOUNT_ROOT == /?* ]] || problems+=("MOUNT_ROOT must be an absolute path")
}

check_pbs_settings() {
  [[ -n $PBS_SERVER ]] || problems+=("PBS_SERVER is not set")
  [[ -n $PBS_DATASTORE ]] || problems+=("PBS_DATASTORE is not set")
  if [[ -z $PBS_AUTH_ID ]]; then
    problems+=("PBS_AUTH_ID is not set")
  elif [[ $PBS_AUTH_ID != *@*'!'* ]]; then
    problems+=("PBS_AUTH_ID must be an API token id like 'unraid-backup@pbs!unraid', got '$PBS_AUTH_ID'")
  fi
  [[ -r $PBS_TOKEN_FILE ]] || problems+=("API token secret not readable: $PBS_TOKEN_FILE (run proxmox/pbs-setup.sh)")
  if [[ $PBS_ENCRYPTION == true && ! -r $PBS_KEYFILE ]]; then
    problems+=("PBS_ENCRYPTION=true but the key file is missing: $PBS_KEYFILE (run: upb init-key)")
  fi
  case $PBS_CHANGE_DETECTION_MODE in
    '' | legacy | data | metadata) ;;
    *) problems+=("PBS_CHANGE_DETECTION_MODE must be legacy, data or metadata") ;;
  esac
}

check_offsite_settings() {
  local n
  [[ -n $OFFSITE_REPOSITORY ]] || problems+=("OFFSITE_REPOSITORY is not set")
  if [[ $OFFSITE_MOUNT_ROOT != /?* ]]; then
    problems+=("OFFSITE_MOUNT_ROOT must be an absolute path")
  elif [[ ${OFFSITE_MOUNT_ROOT%/} == "${MOUNT_ROOT%/}" ]]; then
    problems+=("OFFSITE_MOUNT_ROOT must differ from MOUNT_ROOT, so backups and offsite copies can run at the same time")
  fi
  [[ -r $OFFSITE_PASSWORD_FILE ]] ||
    problems+=("offsite password file not readable: $OFFSITE_PASSWORD_FILE (see docs/offsite.md)")
  if [[ $OFFSITE_REPOSITORY == rclone:* && -n $OFFSITE_RCLONE_CONFIG && ! -r $OFFSITE_RCLONE_CONFIG ]]; then
    problems+=("rclone config not readable: $OFFSITE_RCLONE_CONFIG (see docs/offsite.md)")
  fi
  for n in OFFSITE_KEEP_DAILY OFFSITE_KEEP_WEEKLY OFFSITE_KEEP_MONTHLY; do
    [[ ${!n} =~ ^[0-9]+$ ]] || problems+=("$n must be a number")
  done
  [[ $OFFSITE_PRUNE_WEEKDAY =~ ^[1-7]?$ ]] ||
    problems+=("OFFSITE_PRUNE_WEEKDAY must be 1 (Monday) to 7 (Sunday), or empty for never")
  [[ $OFFSITE_CHECK_DAY =~ ^([1-9]|[12][0-9]|3[01])?$ ]] ||
    problems+=("OFFSITE_CHECK_DAY must be a day of the month (1-31), or empty for never")
}

# Prints every collected problem; returns 1 if there were any.
report_problems() {
  local p
  ((${#problems[@]})) || return 0
  for p in "${problems[@]}"; do error "config: $p"; done
  return 1
}

# Checks the settings needed to run backups. Reports every problem, returns 1 if any.
validate_config() {
  local -a problems=()
  check_source_settings
  check_pbs_settings
  report_problems || return 1
  [[ -n $PBS_FINGERPRINT ]] || warn "PBS_FINGERPRINT is empty: this only works if the PBS certificate is trusted"
  return 0
}

# Checks the settings needed for offsite copies.
validate_offsite_config() {
  local -a problems=()
  check_source_settings
  check_offsite_settings
  report_problems
}

# Sends all further output to the terminal and a timestamped log file.
setup_logging() {
  mkdir -p "$LOG_DIR" || die "cannot create log dir $LOG_DIR"
  UPB_LOG_FILE="$LOG_DIR/upb-$1-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$UPB_LOG_FILE") 2>&1
  find "$LOG_DIR" -maxdepth 1 -name 'upb-*.log' -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null
}

# acquire_lock [lock-file] — backups, offsite copies and host backups each
# have their own lock, so they can overlap but never run twice.
acquire_lock() {
  local file=${1:-$LOCK_FILE}
  exec 9>"$file" || die "cannot open lock file $file"
  flock -n 9 || die "another upb run is already in progress (lock: $file)"
}
