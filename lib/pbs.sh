# shellcheck shell=bash
# Thin wrapper around proxmox-backup-client.

PBS_CLIENT=""

# user@realm!token@host:port:datastore
pbs_repository() {
  printf '%s@%s:%s:%s' "$PBS_AUTH_ID" "$PBS_SERVER" "$PBS_PORT" "$PBS_DATASTORE"
}

ensure_client() {
  if ! PBS_CLIENT=$(command -v "$PBS_CLIENT_CMD"); then
    error "$PBS_CLIENT_CMD not found (it ships with Proxmox Backup Server: apt install proxmox-backup-client)"
    return 1
  fi
}

# Appends --ns to the named array when a namespace is configured.
add_ns_args() {
  local -n _ns_args=$1
  if [[ -n $PBS_NAMESPACE ]]; then _ns_args+=(--ns "$PBS_NAMESPACE"); fi
}

# Appends --keyfile to the named array when encryption is enabled.
add_key_args() {
  local -n _key_args=$1
  if [[ $PBS_ENCRYPTION == true ]]; then _key_args+=(--keyfile "$PBS_KEYFILE"); fi
}

# Runs the client against the configured repository. Credentials are passed
# through the environment, never on the command line.
pbs_client() {
  if dry_run; then
    info "[dry-run] proxmox-backup-client $(quote_args "$@")"
    return 0
  fi
  (
    PBS_REPOSITORY=$(pbs_repository)
    PBS_PASSWORD=$(read_secret "$PBS_TOKEN_FILE") || exit 1
    export PBS_REPOSITORY PBS_PASSWORD
    if [[ -n $PBS_FINGERPRINT ]]; then export PBS_FINGERPRINT; else unset PBS_FINGERPRINT; fi
    exec "$PBS_CLIENT" "$@"
  )
}

# pbs_backup <backup-id> <name.pxar:/path>... — uses the job's EXCLUDES.
pbs_backup() {
  local backup_id=$1 pattern
  shift
  local -a args=(backup "$@" --backup-type host --backup-id "$backup_id")
  add_ns_args args
  if [[ $PBS_ENCRYPTION == true ]]; then
    args+=(--keyfile "$PBS_KEYFILE" --crypt-mode encrypt)
  else
    # Explicit, so a default key in ~/.config/proxmox-backup is never picked up.
    args+=(--crypt-mode none)
  fi
  if [[ -n $PBS_CHANGE_DETECTION_MODE ]]; then
    args+=(--change-detection-mode "$PBS_CHANGE_DETECTION_MODE")
  fi
  for pattern in "${EXCLUDES[@]}"; do args+=(--exclude "$pattern"); done
  args+=("${PBS_EXTRA_ARGS[@]}")
  pbs_client "${args[@]}"
}
