#!/bin/bash
# Install or update upb on the Proxmox Backup Server VM. Run as root from a
# copy of this repository. Safe to re-run: existing config and job files are
# never touched.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${UPB_APP_DIR:-/opt/upb}"
CONFIG_DIR="${UPB_CONFIG_DIR:-/etc/upb}"
SYSTEMD_DIR="${UPB_SYSTEMD_DIR:-/etc/systemd/system}"

say() { printf '==> %s\n' "$*"; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "run as root"
[[ -f $SRC/bin/upb ]] || die "run install.sh from the repository folder"
command -v proxmox-backup-client >/dev/null ||
  die "proxmox-backup-client not found; run this on the Proxmox Backup Server"

if ! command -v mount.nfs >/dev/null; then
  say "Installing nfs-common"
  apt-get update -q
  apt-get install -y -q nfs-common
fi

say "Installing upb $(cat "$SRC/VERSION") to $APP_DIR"
rm -rf "$APP_DIR.new"
mkdir -p "$APP_DIR.new"
cp -r "$SRC/bin" "$SRC/lib" "$SRC/VERSION" "$APP_DIR.new/"
rm -rf "$APP_DIR"
mv "$APP_DIR.new" "$APP_DIR"
ln -sf "$APP_DIR/bin/upb" /usr/local/bin/upb

mkdir -p "$CONFIG_DIR/jobs.d" "$CONFIG_DIR/secrets"
chmod 700 "$CONFIG_DIR/secrets"
if [[ -e $CONFIG_DIR/upb.conf ]]; then
  say "Keeping existing $CONFIG_DIR/upb.conf"
else
  cp "$SRC/config/upb.conf.example" "$CONFIG_DIR/upb.conf"
  say "Created $CONFIG_DIR/upb.conf"
fi
for example in "$SRC"/config/jobs.d/*.conf.example; do
  target="$CONFIG_DIR/jobs.d/$(basename "$example" .example)"
  if [[ ! -e $target ]]; then
    cp "$example" "$target"
    say "Created $target"
  fi
done

install -m 0644 "$SRC/systemd/upb-backup.service" "$SRC/systemd/upb-backup.timer" "$SYSTEMD_DIR/"
systemctl daemon-reload
say "Installed the upb-backup service and timer (not enabled yet)"

cat <<EOF

Next steps:
  1. ./proxmox/pbs-setup.sh         # datastore, backup-only token, schedules
  2. Edit $CONFIG_DIR/upb.conf and the jobs in $CONFIG_DIR/jobs.d/
  3. upb check                      # config, PBS, and every NFS export
  4. upb backup                     # first run
  5. systemctl enable --now upb-backup.timer
EOF
