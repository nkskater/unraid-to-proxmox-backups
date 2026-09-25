#!/usr/bin/env bash
# Prepare this Proxmox Backup Server for upb. Run as root on the PBS VM.
# Safe to re-run: existing objects are kept, and schedules and retention are
# updated to the values below.
#
#   DATASTORE_PATH=/mnt/datastore/unraid ./pbs-setup.sh
#
# Creates: a datastore (if DATASTORE_PATH is set), a user with an API token
# that may only *add* backups (no delete or prune), plus prune, verify and
# garbage-collection schedules. The token secret and the certificate
# fingerprint are written straight into upb's config.
set -euo pipefail

DATASTORE="${DATASTORE:-unraid}"
DATASTORE_PATH="${DATASTORE_PATH:-}"
NAMESPACE="${NAMESPACE:-}"
PBS_USER="${PBS_USER:-unraid-backup@pbs}"
TOKEN_NAME="${TOKEN_NAME:-unraid}"
UPB_CONF="${UPB_CONF:-/etc/upb/upb.conf}"
TOKEN_FILE="${TOKEN_FILE:-/etc/upb/secrets/pbs-token}"

# Retention, applied by PBS after the nightly backup (upb runs at 05:00).
PRUNE_SCHEDULE="${PRUNE_SCHEDULE:-08:00}"
KEEP_LAST="${KEEP_LAST:-3}"
KEEP_DAILY="${KEEP_DAILY:-14}"
KEEP_WEEKLY="${KEEP_WEEKLY:-8}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
KEEP_YEARLY="${KEEP_YEARLY:-3}"
GC_SCHEDULE="${GC_SCHEDULE:-09:00}"
# Re-read and checksum every snapshot older than VERIFY_OUTDATED_DAYS.
VERIFY_SCHEDULE="${VERIFY_SCHEDULE:-sat 10:00}"
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

# json_has <json> <key> <value> — true if the JSON contains "key":"value".
json_has() {
  local compact=${1//[[:space:]]/}
  [[ $compact == *"\"$2\":\"$3\""* ]]
}

command -v proxmox-backup-manager >/dev/null || die "run this on the Proxmox Backup Server"

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
  echo "exists (to issue a new secret: proxmox-backup-manager user delete-token $PBS_USER $TOKEN_NAME,"
  echo "then re-run this script)"
else
  output=$(pbm user generate-token "$PBS_USER" "$TOKEN_NAME")
  secret=$(sed -nE 's/.*"value"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' <<<"$output" | head -n 1)
  if [[ -n $secret ]]; then
    mkdir -p "$(dirname "$TOKEN_FILE")"
    chmod 700 "$(dirname "$TOKEN_FILE")"
    (
      umask 077
      printf '%s\n' "$secret" >"$TOKEN_FILE"
    )
    echo "created; secret saved to $TOKEN_FILE"
  else
    echo "$output"
    echo "Could not read the secret from the output above. Save its 'value' to $TOKEN_FILE"
    echo "now: it is shown only once."
  fi
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

say "upb config"
fingerprint=$(pbm cert info | awk -F': ' '/[Ff]ingerprint/ { print $2; exit }')
if [[ -f $UPB_CONF ]] && grep -q '^PBS_FINGERPRINT=""' "$UPB_CONF"; then
  sed -i "s/^PBS_FINGERPRINT=\"\"/PBS_FINGERPRINT=\"$fingerprint\"/" "$UPB_CONF"
  echo "wrote PBS_FINGERPRINT to $UPB_CONF"
fi

cat <<EOF

Done. $UPB_CONF should contain:

  PBS_SERVER="localhost"
  PBS_DATASTORE="$DATASTORE"
  PBS_NAMESPACE="$NAMESPACE"
  PBS_AUTH_ID="$TOKEN_ID"
  PBS_FINGERPRINT="$fingerprint"
EOF
