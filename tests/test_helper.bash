# shellcheck shell=bash
# Shared setup: a throwaway config dir, a fake Unraid ($STUB_EXPORTS) served by
# the mount stubs, and stubbed client/mail/curl.

setup_upb() {
  UPB_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export UPB_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  export STUB_MOUNTS="$BATS_TEST_TMPDIR/mounts"
  export STUB_EXPORTS="$BATS_TEST_TMPDIR/unraid"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
  MNT="$BATS_TEST_TMPDIR/mnt"
  unset STUB_PBS_EXIT STUB_MOUNT_FAIL STUB_MOUNT_SILENT STUB_CURL_EXIT STUB_PBM_EXISTING

  mkdir -p "$UPB_CONFIG_DIR/jobs.d" "$UPB_CONFIG_DIR/secrets" \
    "$STUB_EXPORTS/mnt/user/docs" "$STUB_EXPORTS/mnt/user/photos" "$STUB_EXPORTS/mnt/user/empty"
  : >"$STUB_LOG"
  : >"$STUB_MOUNTS"
  echo "letter" >"$STUB_EXPORTS/mnt/user/docs/letter.txt"
  echo "jpeg" >"$STUB_EXPORTS/mnt/user/photos/img.jpg"
  touch -d '2 hours ago' "$STUB_EXPORTS/mnt/user/docs/letter.txt" "$STUB_EXPORTS/mnt/user/photos/img.jpg"
  echo "s3cr3t-token" >"$UPB_CONFIG_DIR/secrets/pbs-token"

  cat >"$UPB_CONFIG_DIR/upb.conf" <<EOF
UNRAID_HOST="unraid.test"
MOUNT_ROOT="$MNT"
PBS_DATASTORE="store1"
PBS_AUTH_ID="unraid-backup@pbs!unraid"
PBS_FINGERPRINT="aa:bb:cc"
PBS_CLIENT_CMD="$BATS_TEST_DIRNAME/stubs/proxmox-backup-client"
LOG_DIR="$BATS_TEST_TMPDIR/logs"
LOCK_FILE="$BATS_TEST_TMPDIR/upb.lock"
QUIET_POLL_SECONDS=1
EOF
}

upb() { bash "$UPB_ROOT/bin/upb" "$@"; }

# add_job <file-name> <body>
add_job() { printf '%s\n' "$2" >"$UPB_CONFIG_DIR/jobs.d/$1"; }

# Lines of the call log that start with the given prefix.
calls() { grep -- "^$1" "$STUB_LOG" || true; }
