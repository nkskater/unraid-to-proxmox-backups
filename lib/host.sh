# shellcheck shell=bash
# Configuration backups of a Proxmox VE node, run on the node itself: /etc
# (including the /etc/pve cluster filesystem), /root, /usr/local, cron jobs and
# a consistent copy of the cluster database go to a PBS as one snapshot in
# group host/<HOST_BACKUP_ID>. Settings: $UPB_CONFIG_DIR/host-backup.conf.

# Defaults for host-backup.conf, applied on top of set_config_defaults.
# shellcheck disable=SC2034  # read by lib/pbs.sh and the host commands
set_host_defaults() {
  PBS_SERVER=""
  PBS_NAMESPACE="pve-hosts"
  PBS_AUTH_ID="pve-host@pbs!hosts"
  PBS_TOKEN_FILE="$UPB_CONFIG_DIR/secrets/pve-host-token"
  PBS_KEYFILE="$UPB_CONFIG_DIR/secrets/host-encryption.key"
  PBS_CHANGE_DETECTION_MODE=""
  COMMON_EXCLUDES=()
  LOCK_FILE="/run/upb-host-backup.lock"

  HOST_BACKUP_ID="pve-$(hostname -s 2>/dev/null || echo host)"
  HOST_BACKUP_PATHS=(/etc /root /usr/local /var/spool/cron)
  HOST_BACKUP_INCLUDE_DEV=(/etc/pve)
  HOST_BACKUP_EXCLUDES=("/.cache/")
  PVE_CLUSTER_DB="/var/lib/pve-cluster/config.db"
  SQLITE3_CMD="sqlite3"
}

load_host_config() {
  local conf="$UPB_CONFIG_DIR/host-backup.conf"
  set_config_defaults
  set_host_defaults
  if [[ ! -r $conf ]]; then
    die "config not found: $conf (run: install.sh --pve-host)"
  fi
  # shellcheck source=/dev/null
  source "$conf" || die "failed to load $conf"
}

validate_host_config() {
  local -a problems=()
  local p
  check_pbs_settings
  [[ $HOST_BACKUP_ID =~ $BACKUP_ID_RE ]] || problems+=("invalid HOST_BACKUP_ID '$HOST_BACKUP_ID'")
  ((${#HOST_BACKUP_PATHS[@]})) || problems+=("HOST_BACKUP_PATHS is empty")
  for p in "${HOST_BACKUP_PATHS[@]}" "${HOST_BACKUP_INCLUDE_DEV[@]}"; do
    [[ $p == /* ]] || problems+=("HOST_BACKUP_PATHS and HOST_BACKUP_INCLUDE_DEV need absolute paths, got '$p'")
  done
  report_problems || return 1
  [[ -n $PBS_FINGERPRINT ]] || warn "PBS_FINGERPRINT is empty: this only works if the PBS certificate is trusted"
  return 0
}

# /usr/local -> usr-local
host_archive_name() {
  local name=${1#/}
  name=${name%/}
  name=${name//\//-}
  name=${name//[^A-Za-z0-9_-]/_}
  printf '%s' "${name:-rootfs}"
}

# Archive names of the configured paths plus the cluster database copy.
host_archive_names() {
  local p
  for p in "${HOST_BACKUP_PATHS[@]}"; do host_archive_name "$p"; echo; done
  if [[ -n $PVE_CLUSTER_DB ]]; then echo pve-cluster-db; fi
}

# Backs up this node's configuration. Call it in its own subshell: it sets a
# trap that removes the temporary database copy. HOST_DB_DIR is global so the
# trap can still see it when the subshell exits.
run_host_backup() {
  local -a archives=() include=()
  local p rc

  for p in "${HOST_BACKUP_INCLUDE_DEV[@]}"; do
    # /etc/pve is only filled while the cluster filesystem runs. Never back up
    # its empty mount point in place of the real configuration.
    if [[ -z $(find "$p" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
      error "$p is empty or missing: is the pve-cluster service running?"
      return 1
    fi
    include+=(--include-dev "$p")
  done

  for p in "${HOST_BACKUP_PATHS[@]}"; do
    if [[ -d $p ]]; then
      archives+=("$(host_archive_name "$p").pxar:$p")
    else
      warn "skipping $p: not a folder on this host"
    fi
  done

  if [[ -n $PVE_CLUSTER_DB ]]; then
    if dry_run; then
      HOST_DB_DIR="${TMPDIR:-/var/tmp}/upb-host-backup.XXXXXX"
      info "[dry-run] would copy $PVE_CLUSTER_DB with sqlite3 into $HOST_DB_DIR"
    else
      if ! command -v "$SQLITE3_CMD" >/dev/null; then
        error "$SQLITE3_CMD not found (apt install sqlite3)"
        return 1
      fi
      if [[ ! -r $PVE_CLUSTER_DB ]]; then
        error "cluster database not found: $PVE_CLUSTER_DB"
        return 1
      fi
      HOST_DB_DIR=$(mktemp -d "${TMPDIR:-/var/tmp}/upb-host-backup.XXXXXX") || return 1
      # Removes exactly the one file this function creates, and the empty folder.
      trap 'rm -f "$HOST_DB_DIR/config.db"; rmdir "$HOST_DB_DIR" 2>/dev/null' EXIT
      # A consistent snapshot of the live database, taken without stopping the cluster.
      if ! "$SQLITE3_CMD" "$PVE_CLUSTER_DB" ".backup '$HOST_DB_DIR/config.db'"; then
        error "could not copy the cluster database $PVE_CLUSTER_DB"
        return 1
      fi
    fi
    archives+=("pve-cluster-db.pxar:$HOST_DB_DIR")
  fi
  if ((${#archives[@]} == 0)); then
    error "nothing to back up: none of HOST_BACKUP_PATHS exists"
    return 1
  fi

  EXCLUDES=("${HOST_BACKUP_EXCLUDES[@]}")
  info "backing up the configuration of $(hostname) to host/$HOST_BACKUP_ID"
  # The --include-dev options go along with the archives; the client takes
  # options anywhere on its command line.
  pbs_backup "$HOST_BACKUP_ID" "${archives[@]}" "${include[@]}"
  rc=$?
  ((rc == 0)) || error "proxmox-backup-client failed (exit $rc)"
  return "$rc"
}
