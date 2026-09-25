#!/usr/bin/env bash
# Prepare a Proxmox Backup Server to receive the Unraid backups.
#
# Run as root on the PBS host. Safe to re-run: existing objects are kept and
# the schedules and retention are updated to the values below.
#
#   DATASTORE_PATH=/mnt/datastore/unraid ./pbs-setup.sh
#
# Creates: a datastore (if DATASTORE_PATH is set), a user with an API token
# that may only *add* backups (no delete or prune, so a compromised Unraid box
# can't wipe its backups), plus prune, verify and garbage-collection schedules.
set -euo pipefail

DATASTORE="${DATASTORE:-unraid}"
DATASTORE_PATH="${DATASTORE_PATH:-}"
NAMESPACE="${NAMESPACE:-}"
PBS_USER="${PBS_USER:-unraid-backup@pbs}"
TOKEN_NAME="${TOKEN_NAME:-unraid}"

# Retention, applied by PBS on its own schedule (backups run at night on Unraid).
PRUNE_SCHEDULE="${PRUNE_SCHEDULE:-06:00}"
KEEP_LAST="${KEEP_LAST:-3}"
KEEP_DAILY="${KEEP_DAILY:-14}"
KEEP_WEEKLY="${KEEP_WEEKLY:-8}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
KEEP_YEARLY="${KEEP_YEARLY:-3}"
GC_SCHEDULE="${GC_SCHEDULE:-07:00}"
# Re-read and checksum every snapshot older than VERIFY_OUTDATED_DAYS.
VERIFY_SCHEDULE="${VERIFY_SCHEDULE:-sat 08:00}"
VERIFY_OUTDATED_DAYS="${VERIFY_OUTDATED_DAYS:-30}"

TOKEN_ID="$PBS_USER!$TOKEN_NAME"
PRUNE_JOB_ID="${DATASTORE}-retention"
VERIFY_JOB_ID="${DATASTORE}-verify"
ACL_PATH="/datastore/$DATASTORE${NAMESPACE:+/$NAMESPACE}"

say() { printf '\n==> %s\n' "$*"; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
pbm() { proxmox-backup-manager "$@"; }

# json_has <json> <key> <value> — true if the (compact) JSON contains "key":"value".
json_has() {
  local compact=${1//[[:space:]]/}
  [[ $compact == *"\"$2\":\"$3\""* ]]
}

command -v proxmox-backup-manager >/dev/null || die "run this on the Proxmox Backup Server host"
[[ $EUID -eq 0 ]] || die "run as root"

say "Datastore '$DATASTORE'"
if json_has "$(pbm datastore list --output-format json)" name "$DATASTORE"; then
  echo "exists"
elif [[ -n $DATASTORE_PATH ]]; then
  pbm datastore create "$DATASTORE" "$DATASTORE_PATH" --comment "Unraid backups (upb)"
else
  die "datastore '$DATASTORE' doesn't exist. Create it in the web UI, or set DATASTORE_PATH to create it here"
fi
pbm datastore update "$DATASTORE" --gc-schedule "$GC_SCHEDULE"
echo "garbage collection: $GC_SCHEDULE"

if [[ -n $NAMESPACE ]]; then
  say "Namespace '$NAMESPACE'"
  echo "Log in as root@pam to create it (skip if it already exists):"
  proxmox-backup-client namespace create "$NAMESPACE" --repository "root@pam@localhost:$DATASTORE" ||
    echo "Could not create it here; add it in the web UI: Datastore > $DATASTORE > Content > Add Namespace"
fi

say "User '$PBS_USER'"
if json_has "$(pbm user list --output-format json)" userid "$PBS_USER"; then
  echo "exists"
else
  pbm user create "$PBS_USER" --comment "Unraid backups (upb)"
fi

say "API token '$TOKEN_ID'"
if json_has "$(pbm user list-tokens "$PBS_USER" --output-format json)" tokenid "$TOKEN_ID"; then
  echo "exists (its secret was shown when it was created; to issue a new one run"
  echo "  proxmox-backup-manager user delete-token $PBS_USER $TOKEN_NAME"
  echo "and re-run this script)"
else
  echo "Copy the secret ('value') into /boot/config/upb/secrets/pbs-token on Unraid."
  echo "It is shown only once:"
  pbm user generate-token "$PBS_USER" "$TOKEN_NAME"
fi

say "Permissions on $ACL_PATH"
# DatastoreBackup: create backups and read back its own, but not delete or prune.
# A token only gets permissions that both it and its user have.
pbm acl update "$ACL_PATH" DatastoreBackup --auth-id "$PBS_USER"
pbm acl update "$ACL_PATH" DatastoreBackup --auth-id "$TOKEN_ID"
echo "DatastoreBackup for $PBS_USER and $TOKEN_ID"

ns_args=()
[[ -n $NAMESPACE ]] && ns_args=(--ns "$NAMESPACE")

say "Prune job '$PRUNE_JOB_ID'"
keep_args=(--keep-last "$KEEP_LAST" --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY"
  --keep-monthly "$KEEP_MONTHLY" --keep-yearly "$KEEP_YEARLY")
if json_has "$(pbm prune-job list --output-format json)" id "$PRUNE_JOB_ID"; then
  pbm prune-job update "$PRUNE_JOB_ID" --schedule "$PRUNE_SCHEDULE" "${keep_args[@]}"
else
  pbm prune-job create "$PRUNE_JOB_ID" --store "$DATASTORE" "${ns_args[@]}" \
    --schedule "$PRUNE_SCHEDULE" "${keep_args[@]}"
fi
echo "$PRUNE_SCHEDULE: keep last $KEEP_LAST, daily $KEEP_DAILY, weekly $KEEP_WEEKLY, monthly $KEEP_MONTHLY, yearly $KEEP_YEARLY"

say "Verify job '$VERIFY_JOB_ID'"
if json_has "$(pbm verify-job list --output-format json)" id "$VERIFY_JOB_ID"; then
  pbm verify-job update "$VERIFY_JOB_ID" --schedule "$VERIFY_SCHEDULE" \
    --ignore-verified true --outdated-after "$VERIFY_OUTDATED_DAYS"
else
  pbm verify-job create "$VERIFY_JOB_ID" --store "$DATASTORE" "${ns_args[@]}" \
    --schedule "$VERIFY_SCHEDULE" --ignore-verified true --outdated-after "$VERIFY_OUTDATED_DAYS"
fi
echo "$VERIFY_SCHEDULE, re-verifying snapshots after $VERIFY_OUTDATED_DAYS days"

fingerprint=$(pbm cert info | awk -F': ' '/[Ff]ingerprint/ { print $2; exit }')
address=$(hostname -I | awk '{ print $1 }')

cat <<EOF

Done. Put these values in /boot/config/upb/upb.conf on Unraid:

  PBS_SERVER="$address"
  PBS_DATASTORE="$DATASTORE"
  PBS_NAMESPACE="$NAMESPACE"
  PBS_AUTH_ID="$TOKEN_ID"
  PBS_FINGERPRINT="$fingerprint"
EOF
