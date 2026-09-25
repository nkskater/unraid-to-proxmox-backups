# shellcheck shell=bash
# Shared setup: a throwaway config dir, stubbed docker/client/notify, and data dirs.

setup_upb() {
  UPB_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DATA="$BATS_TEST_TMPDIR/data"
  export UPB_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
  unset STUB_PBS_EXIT STUB_DOCKER_RUNNING STUB_DOCKER_KNOWN STUB_DOCKER_FAIL

  mkdir -p "$UPB_CONFIG_DIR/jobs.d" "$UPB_CONFIG_DIR/secrets" "$DATA/docs" "$DATA/photos"
  : >"$STUB_LOG"
  echo "s3cr3t-token" >"$UPB_CONFIG_DIR/secrets/pbs-token"
  echo '{"kdf":null}' >"$UPB_CONFIG_DIR/secrets/encryption.key"

  cat >"$UPB_CONFIG_DIR/upb.conf" <<EOF
PBS_SERVER="pbs.test"
PBS_DATASTORE="store1"
PBS_AUTH_ID="unraid-backup@pbs!unraid"
PBS_FINGERPRINT="aa:bb:cc"
PBS_CLIENT_BIN="$BATS_TEST_TMPDIR/no-persistent-client"
PBS_CLIENT_RUNTIME="$BATS_TEST_DIRNAME/stubs/proxmox-backup-client"
STAGING_DIR="$BATS_TEST_TMPDIR/staging"
LOG_DIR="$BATS_TEST_TMPDIR/logs"
LOCK_FILE="$BATS_TEST_TMPDIR/upb.lock"
UNRAID_NOTIFY_CMD="$BATS_TEST_DIRNAME/stubs/notify"
EOF
}

upb() { bash "$UPB_ROOT/bin/upb" "$@"; }

# add_job <file-name> <body>
add_job() { printf '%s\n' "$2" >"$UPB_CONFIG_DIR/jobs.d/$1"; }

# Lines of the call log that start with the given prefix.
calls() { grep -- "^$1" "$STUB_LOG" || true; }
