#!/bin/bash
# Install or update upb. Run as root from a copy of this repository:
#
#   bash install.sh              on the Proxmox Backup Server VM (Unraid backups)
#   bash install.sh --pve-host   on each Proxmox VE node (its own configuration)
#
# Safe to re-run: existing config and job files are never touched.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${UPB_APP_DIR:-/opt/upb}"
CONFIG_DIR="${UPB_CONFIG_DIR:-/etc/upb}"
SYSTEMD_DIR="${UPB_SYSTEMD_DIR:-/etc/systemd/system}"
MODE=pbs

say() { printf '==> %s\n' "$*"; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

case ${1:-} in
  '') ;;
  --pve-host) MODE=pve-host ;;
  *) die "unknown option: $1 (use --pve-host on a Proxmox VE node)" ;;
esac

[[ $EUID -eq 0 ]] || die "run as root"
[[ -f $SRC/bin/upb ]] || die "run install.sh from the repository folder"
if [[ $MODE == pve-host ]]; then
  command -v proxmox-backup-client >/dev/null ||
    die "proxmox-backup-client not found; install it with: apt install proxmox-backup-client"
  [[ -d /etc/pve ]] || say "warning: /etc/pve not found; --pve-host is meant for Proxmox VE nodes"
  if ! command -v sqlite3 >/dev/null; then
    say "Installing sqlite3 (for a consistent copy of the cluster database)"
    # A node without an enterprise subscription may fail to update that
    # repository; the package usually still installs from the others.
    apt-get update -q || say "warning: apt-get update reported errors, installing anyway"
    apt-get install -y -q sqlite3
  fi
else
  command -v proxmox-backup-client >/dev/null ||
    die "proxmox-backup-client not found; run this on the Proxmox Backup Server"
  if ! command -v mount.nfs >/dev/null; then
    say "Installing nfs-common"
    apt-get update -q
    apt-get install -y -q nfs-common
  fi
fi

say "Installing upb $(cat "$SRC/VERSION") to $APP_DIR"
rm -rf "$APP_DIR.new"
mkdir -p "$APP_DIR.new"
cp -r "$SRC/bin" "$SRC/lib" "$SRC/VERSION" "$APP_DIR.new/"
rm -rf "$APP_DIR"
mv "$APP_DIR.new" "$APP_DIR"
chmod 0755 "$APP_DIR/bin/upb"
ln -sf "$APP_DIR/bin/upb" /usr/local/bin/upb

mkdir -p "$CONFIG_DIR/secrets"
chmod 700 "$CONFIG_DIR/secrets"

# install_config <example> <target> — copies the example unless the target exists.
install_config() {
  if [[ -e $2 ]]; then
    say "Keeping existing $2"
  else
    cp "$1" "$2"
    say "Created $2"
  fi
}

if [[ $MODE == pve-host ]]; then
  install_config "$SRC/config/host-backup.conf.example" "$CONFIG_DIR/host-backup.conf"
  install -m 0644 "$SRC/systemd/upb-host-backup.service" "$SRC/systemd/upb-host-backup.timer" "$SYSTEMD_DIR/"
  systemctl daemon-reload
  say "Installed the upb-host-backup service and timer"
  cat <<EOF

Next steps (docs/pve-host-backup.md):
  1. On the PBS on Unraid: run proxmox/pbs-setup.sh for the pve-hosts namespace
  2. Save the token secret to $CONFIG_DIR/secrets/pve-host-token (chmod 600)
  3. Edit $CONFIG_DIR/host-backup.conf: PBS_SERVER, PBS_DATASTORE, PBS_FINGERPRINT
  4. upb host-backup
  5. systemctl enable --now upb-host-backup.timer
EOF
  exit 0
fi

mkdir -p "$CONFIG_DIR/jobs.d"
install_config "$SRC/config/upb.conf.example" "$CONFIG_DIR/upb.conf"
for example in "$SRC"/config/jobs.d/*.conf.example; do
  target="$CONFIG_DIR/jobs.d/$(basename "$example" .example)"
  if [[ ! -e $target ]]; then
    cp "$example" "$target"
    say "Created $target"
  fi
done

install -m 0644 "$SRC/systemd/upb-backup.service" "$SRC/systemd/upb-backup.timer" \
  "$SRC/systemd/upb-offsite.service" "$SRC/systemd/upb-offsite.timer" "$SYSTEMD_DIR/"
systemctl daemon-reload
say "Installed the upb-backup and upb-offsite services and timers (enabled timers stay enabled)"

cat <<EOF

First install? Next steps:
  1. ./proxmox/pbs-setup.sh         # datastore, backup-only token, schedules
  2. Edit $CONFIG_DIR/upb.conf and the jobs in $CONFIG_DIR/jobs.d/
  3. upb check                      # config, PBS, and every NFS export
  4. upb backup                     # first run
  5. systemctl enable --now upb-backup.timer
Offsite copies to Google Drive: docs/offsite.md
EOF
