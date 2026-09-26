#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats runs each test in a subshell

load test_helper

setup() {
  setup_upb
  NODE="$BATS_TEST_TMPDIR/node"
  mkdir -p "$NODE/etc/pve/nodes/pve1" "$NODE/etc/network" "$NODE/root/.cache" \
    "$NODE/usr/local/bin" "$NODE/var/lib/pve-cluster"
  echo "pbs: unraid-pbs" >"$NODE/etc/pve/storage.cfg"
  echo "auto vmbr0" >"$NODE/etc/network/interfaces"
  echo "sqlite" >"$NODE/var/lib/pve-cluster/config.db"
  echo "h0st-t0ken" >"$UPB_CONFIG_DIR/secrets/pve-host-token"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  cat >"$UPB_CONFIG_DIR/host-backup.conf" <<EOF
PBS_SERVER="192.0.2.30"
PBS_DATASTORE="pbs_data"
PBS_FINGERPRINT="dd:ee:ff"
PBS_CLIENT_CMD="$BATS_TEST_DIRNAME/stubs/proxmox-backup-client"
HOST_BACKUP_ID="pve-test"
HOST_BACKUP_PATHS=("$NODE/etc" "$NODE/root" "$NODE/usr/local" "$NODE/var/spool/cron")
HOST_BACKUP_INCLUDE_DEV=("$NODE/etc/pve")
PVE_CLUSTER_DB="$NODE/var/lib/pve-cluster/config.db"
LOG_DIR="$BATS_TEST_TMPDIR/logs"
LOCK_FILE="$BATS_TEST_TMPDIR/host.lock"
EOF
  # Archive names are derived from the folder paths, which live under the test dir here.
  A=${NODE#/}
  A=${A//\//-}
  A=${A//[^A-Za-z0-9_-]/_}
}

@test "archive names come from the folder paths" {
  run bash -c "source '$UPB_ROOT/lib/host.sh'
    for p in /etc /root /usr/local /var/spool/cron/ / '/opt/my app'; do host_archive_name \"\$p\"; echo; done"
  [ "$output" = "etc
root
usr-local
var-spool-cron
rootfs
opt-my_app" ]
}

@test "host-backup sends /etc with the cluster filesystem, /root, /usr/local and the cluster database" {
  run upb host-backup
  [ "$status" -eq 0 ]
  [[ $output == *"skipping $NODE/var/spool/cron: not a folder on this host"* ]]
  run calls "pbs backup"
  [ "${#lines[@]}" -eq 1 ]
  [[ $output == "pbs backup $A-etc.pxar:$NODE/etc $A-root.pxar:$NODE/root $A-usr-local.pxar:$NODE/usr/local pve-cluster-db.pxar:$TMPDIR/upb-host-backup."* ]]
  [[ $output == *" --include-dev $NODE/etc/pve --backup-type host --backup-id pve-test --ns pve-hosts --crypt-mode none --exclude /.cache/" ]]
  [[ $output != *--change-detection-mode* ]]
  grep -qx "saw pve-cluster-db.pxar: config.db " "$STUB_LOG"
  calls sqlite3 | grep -q "^sqlite3 $NODE/var/lib/pve-cluster/config.db .backup '$TMPDIR/upb-host-backup\..*/config.db'$"
  # The temporary copy is gone again.
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "host-backup credentials go through the environment" {
  run upb host-backup
  [ "$status" -eq 0 ]
  grep -qx 'env PBS_REPOSITORY=pve-host@pbs!hosts@192.0.2.30:8007:pbs_data PBS_PASSWORD=h0st-t0ken PBS_FINGERPRINT=dd:ee:ff' "$STUB_LOG"
  run grep -c h0st-t0ken < <(calls "pbs ")
  [ "$output" = 0 ]
}

@test "an empty /etc/pve is never backed up in place of the cluster filesystem" {
  rm -r "$NODE/etc/pve/nodes" "$NODE/etc/pve/storage.cfg"
  run upb host-backup
  [ "$status" -eq 1 ]
  [[ $output == *"$NODE/etc/pve is empty or missing: is the pve-cluster service running?"* ]]
  [ -z "$(calls 'pbs backup')" ]
}

@test "a missing cluster database or sqlite3 fails the backup" {
  echo "PVE_CLUSTER_DB=\"$NODE/nope.db\"" >>"$UPB_CONFIG_DIR/host-backup.conf"
  run upb host-backup
  [ "$status" -eq 1 ]
  [[ $output == *"cluster database not found"* ]]
  [ -z "$(calls 'pbs backup')" ]

  echo "PVE_CLUSTER_DB=\"$NODE/var/lib/pve-cluster/config.db\"
SQLITE3_CMD=\"$BATS_TEST_TMPDIR/no-sqlite3\"" >>"$UPB_CONFIG_DIR/host-backup.conf"
  run upb host-backup
  [ "$status" -eq 1 ]
  [[ $output == *"not found (apt install sqlite3)"* ]]

  echo 'SQLITE3_CMD="sqlite3"' >>"$UPB_CONFIG_DIR/host-backup.conf"
  export STUB_SQLITE_FAIL=1
  run upb host-backup
  [ "$status" -eq 1 ]
  [[ $output == *"could not copy the cluster database"* ]]
  [ -z "$(calls 'pbs backup')" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "host-backup failures are notified" {
  export STUB_PBS_EXIT=1
  cat >>"$UPB_CONFIG_DIR/host-backup.conf" <<'EOF'
NOTIFY_EMAIL="me@example.com"
HEALTHCHECK_URL="https://hc.test/ping/node"
EOF
  run upb host-backup
  [ "$status" -eq 1 ]
  grep -qx "Subject: upb host-backup: 1 of 1 backup(s) failed" "$STUB_LOG"
  grep -qx "FAIL  host/pve-test (exit 1)" "$STUB_LOG"
  calls curl | grep -q "https://hc.test/ping/node/fail"
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "host-restore restores each archive into its own folder" {
  run upb host-restore "$BATS_TEST_TMPDIR/restore"
  [ "$status" -eq 0 ]
  run calls "pbs restore"
  [ "${#lines[@]}" -eq 5 ]
  [ "${lines[0]}" = "pbs restore host/pve-test $A-etc.pxar $BATS_TEST_TMPDIR/restore/$A-etc --ns pve-hosts" ]
  [ "${lines[4]}" = "pbs restore host/pve-test pve-cluster-db.pxar $BATS_TEST_TMPDIR/restore/pve-cluster-db --ns pve-hosts" ]

  run upb host-restore "$BATS_TEST_TMPDIR/restore2" host/pve-other/2026-09-01T05:30:00Z
  calls "pbs restore" | grep -q "^pbs restore host/pve-other/2026-09-01T05:30:00Z $A-root.pxar "

  mkdir -p "$BATS_TEST_TMPDIR/full"
  touch "$BATS_TEST_TMPDIR/full/file"
  run upb host-restore "$BATS_TEST_TMPDIR/full"
  [ "$status" -eq 1 ]
  [[ $output == *"is not empty"* ]]
}

@test "host-backup dry run copies and sends nothing" {
  run upb host-backup --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] proxmox-backup-client backup $A-etc.pxar:$NODE/etc"* ]]
  [[ $output == *"would copy $NODE/var/lib/pve-cluster/config.db with sqlite3"* ]]
  [[ $output == *"pve-cluster-db.pxar:$TMPDIR/upb-host-backup.XXXXXX "* ]]
  [ -z "$(ls -A "$TMPDIR")" ]
  [ ! -s "$STUB_LOG" ]
}

@test "the shipped host config loads and asks for the PBS server" {
  cp "$UPB_ROOT/config/host-backup.conf.example" "$UPB_CONFIG_DIR/host-backup.conf"
  run upb host-backup
  [ "$status" -eq 1 ]
  [[ $output == *"PBS_SERVER is not set"* ]]
  [[ $output == *"PBS_DATASTORE is not set"* ]]
  [ -z "$(calls 'pbs ')" ]
}
