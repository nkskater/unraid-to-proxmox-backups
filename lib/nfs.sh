# shellcheck shell=bash
# Read-only NFS mounts of Unraid shares.

# mount_export <unraid-path> <mountpoint>
# Mounts UNRAID_HOST:<unraid-path> and refuses to continue unless a non-empty
# share is really mounted there, so an unmounted (empty) folder is never
# backed up in its place.
mount_export() {
  local export=$1 mnt=$2
  local source="$UNRAID_HOST:$export"
  if dry_run; then
    info "[dry-run] mount -t nfs -o $NFS_OPTIONS $source $mnt"
    return 0
  fi
  if ! mkdir -p "$mnt"; then
    error "cannot create mount point $mnt"
    return 1
  fi
  if mountpoint -q "$mnt"; then
    warn "$mnt is still mounted from an earlier run, remounting"
    if ! umount "$mnt"; then
      error "cannot unmount $mnt"
      return 1
    fi
  fi
  if ! mount -t nfs -o "$NFS_OPTIONS" "$source" "$mnt"; then
    error "cannot mount $source (is the share exported to this host? see docs/unraid-setup.md)"
    return 1
  fi
  if ! mountpoint -q "$mnt"; then
    error "$mnt is not a mount point after mounting $source"
    return 1
  fi
  if [[ -z $(find "$mnt" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    error "$source is empty; refusing to back up an empty share"
    return 1
  fi
  info "mounted $source on $mnt (read-only)"
}

unmount_export() {
  local mnt=$1
  dry_run && return 0
  mountpoint -q "$mnt" || return 0
  umount "$mnt" 2>/dev/null || umount -l "$mnt" || warn "could not unmount $mnt"
}

# Waits until nothing under the directory changed for QUIET_MINUTES, e.g. while
# Appdata Backup is still writing its archives. Gives up after QUIET_TIMEOUT_MINUTES.
wait_for_quiet() {
  local dir=$1 waited=0 limit=$((QUIET_TIMEOUT_MINUTES * 60))
  if dry_run; then
    info "[dry-run] would wait until nothing in $dir changed for $QUIET_MINUTES min"
    return 0
  fi
  while [[ -n $(find "$dir" -mindepth 1 -mmin -"$QUIET_MINUTES" -print -quit 2>/dev/null) ]]; do
    if ((waited >= limit)); then
      error "files in $dir were still changing after $QUIET_TIMEOUT_MINUTES min; giving up"
      return 1
    fi
    if ((waited == 0)); then
      info "files in $dir changed in the last $QUIET_MINUTES min, waiting for them to settle"
    fi
    sleep "$QUIET_POLL_SECONDS"
    waited=$((waited + QUIET_POLL_SECONDS))
  done
}
