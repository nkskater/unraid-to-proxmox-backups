#!/bin/bash
# Install or update upb on an Unraid server. Run as root from a copy of this
# repository. Safe to re-run: existing config and job files are never touched.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${UPB_CONFIG_DIR:-/boot/config/upb}"
APP_DIR="$CONFIG_DIR/app"
USER_SCRIPTS_DIR="/boot/config/plugins/user.scripts/scripts"

say() { printf '==> %s\n' "$*"; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "run as root"
[[ -f $SRC/bin/upb ]] || die "run install.sh from the repository folder"
[[ -d /boot/config || -n ${UPB_CONFIG_DIR:-} ]] || die "/boot/config not found; is this Unraid?"

say "Installing upb $(cat "$SRC/VERSION") to $APP_DIR"
mkdir -p "$CONFIG_DIR/jobs.d" "$CONFIG_DIR/secrets" "$CONFIG_DIR/bin"
rm -rf "$APP_DIR.new"
mkdir -p "$APP_DIR.new"
cp -r "$SRC/bin" "$SRC/lib" "$SRC/VERSION" "$APP_DIR.new/"
rm -rf "$APP_DIR"
mv "$APP_DIR.new" "$APP_DIR"

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

# The flash drive is mounted without exec permission, so the command is a
# small wrapper in RAM. It disappears on reboot; the scheduled User Script
# recreates it on every run.
printf '#!/bin/bash\nexec bash %q "$@"\n' "$APP_DIR/bin/upb" >/usr/local/bin/upb
chmod 0755 /usr/local/bin/upb
say "Installed /usr/local/bin/upb"

if [[ -d $(dirname "$USER_SCRIPTS_DIR") ]]; then
  mkdir -p "$USER_SCRIPTS_DIR/upb-backup"
  cp "$SRC/unraid/user-scripts/upb-backup/script" "$USER_SCRIPTS_DIR/upb-backup/script"
  echo "Back up important data to Proxmox Backup Server (upb)" >"$USER_SCRIPTS_DIR/upb-backup/description"
  say "Installed the 'upb-backup' User Script (set its schedule in Settings > User Scripts)"
else
  say "User Scripts plugin not found: install it from Community Applications to schedule backups"
fi

if [[ ! -f $CONFIG_DIR/bin/proxmox-backup-client ]]; then
  say "Downloading proxmox-backup-client"
  bash "$APP_DIR/bin/upb" install-client ||
    say "Client download failed; run 'upb install-client' later (see docs/unraid-setup.md)"
fi

cat <<EOF

Next steps:
  1. Edit $CONFIG_DIR/upb.conf (PBS server, datastore, token id, fingerprint)
  2. Put the API token secret in $CONFIG_DIR/secrets/pbs-token
  3. Review the jobs in $CONFIG_DIR/jobs.d/
  4. upb init-key          # create the encryption key and store a copy offline
  5. upb check             # verify config, jobs and the connection
  6. upb backup --dry-run  # then: upb backup
EOF
