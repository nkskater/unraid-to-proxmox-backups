#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats runs each test in a subshell

load test_helper

setup() { setup_upb; }

@test "backup mounts the export read-only, backs it up and unmounts" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs
EXCLUDES=("*.tmp" "/cache/")'

  run upb backup
  [ "$status" -eq 0 ]

  run grep -E '^(mount|pbs backup|umount)' "$STUB_LOG"
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "mount -t nfs -o ro,soft,timeo=600,retrans=2 unraid.test:/mnt/user/docs $MNT/docs" ]
  [[ ${lines[1]} == "pbs backup docs.pxar:$MNT/docs --backup-type host --backup-id unraid-docs --crypt-mode none --change-detection-mode metadata --exclude \*.tmp --exclude /cache/" ]]
  [ "${lines[2]}" = "umount $MNT/docs" ]
  [ ! -s "$STUB_MOUNTS" ]
}

@test "credentials go through the environment, never the command line" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'

  run upb backup
  [ "$status" -eq 0 ]
  grep -qx 'env PBS_REPOSITORY=unraid-backup@pbs!unraid@localhost:8007:store1 PBS_PASSWORD=s3cr3t-token PBS_FINGERPRINT=aa:bb:cc' "$STUB_LOG"
  run grep -c s3cr3t < <(calls "pbs ")
  [ "$output" = 0 ]
}

@test "encryption, namespace, a custom group and extra args are passed through" {
  echo '{}' >"$UPB_CONFIG_DIR/secrets/encryption.key"
  cat >>"$UPB_CONFIG_DIR/upb.conf" <<'EOF'
PBS_NAMESPACE="unraid"
PBS_ENCRYPTION=true
PBS_CHANGE_DETECTION_MODE=""
PBS_EXTRA_ARGS=(--rate 10MiB)
EOF
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs
BACKUP_ID=custom-id'

  run upb backup
  [ "$status" -eq 0 ]
  run calls "pbs backup"
  [[ $output == *"--backup-id custom-id --ns unraid --keyfile $UPB_CONFIG_DIR/secrets/encryption.key --crypt-mode encrypt --rate 10MiB" ]]
  [[ $output != *--change-detection-mode* ]]
}

@test "disabled jobs are skipped unless named explicitly" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'
  add_job 20-photos.conf 'JOB_ENABLED=false
EXPORT=/mnt/user/photos'

  run upb backup
  [ "$status" -eq 0 ]
  [ "$(calls 'pbs backup' | wc -l)" -eq 1 ]
  calls "pbs backup" | grep -q -- "--backup-id unraid-docs"

  : >"$STUB_LOG"
  run upb backup photos
  [ "$status" -eq 0 ]
  [ "$(calls 'pbs backup' | wc -l)" -eq 1 ]
  calls "pbs backup" | grep -q -- "--backup-id unraid-photos"
}

@test "an unknown job name is an error" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'
  run upb backup nope
  [ "$status" -eq 1 ]
  [[ $output == *"unknown job: nope"* ]]
}

@test "a share that can't be mounted fails its job but not the others" {
  export STUB_MOUNT_FAIL="/mnt/user/photos"
  add_job 10-photos.conf 'EXPORT=/mnt/user/photos'
  add_job 20-docs.conf 'EXPORT=/mnt/user/docs'

  run upb backup
  [ "$status" -eq 1 ]
  [[ $output == *"cannot mount unraid.test:/mnt/user/photos"* ]]
  [[ $output == *"FAIL  photos"* ]]
  [[ $output == *"OK    docs"* ]]
  [ "$(calls 'pbs backup' | wc -l)" -eq 1 ]
  calls "pbs backup" | grep -q -- "--backup-id unraid-docs"
}

@test "an empty share is never backed up" {
  add_job 10-empty.conf 'EXPORT=/mnt/user/empty'

  run upb backup
  [ "$status" -eq 1 ]
  [[ $output == *"is empty; refusing to back up"* ]]
  [ -z "$(calls 'pbs backup')" ]
  [ ! -s "$STUB_MOUNTS" ]
}

@test "a local folder is never backed up in place of a share that didn't mount" {
  export STUB_MOUNT_SILENT="/mnt/user/docs"
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'
  mkdir -p "$MNT/docs"
  echo "local file" >"$MNT/docs/stray.txt"

  run upb backup
  [ "$status" -eq 1 ]
  [[ $output == *"is not a mount point after mounting"* ]]
  [ -z "$(calls 'pbs backup')" ]
}

@test "the share is unmounted when the backup fails" {
  export STUB_PBS_EXIT=2
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'

  run upb backup
  [ "$status" -eq 1 ]
  [[ $output == *"FAIL  docs (exit 2)"* ]]
  calls "umount $MNT/docs" | grep -q .
  [ ! -s "$STUB_MOUNTS" ]
}

@test "a mount left over from an earlier run is replaced" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'
  mkdir -p "$MNT/docs"
  echo "$MNT/docs" >"$STUB_MOUNTS"

  run upb backup
  [ "$status" -eq 0 ]
  [[ $output == *"still mounted from an earlier run"* ]]
  run grep -E '^(mount|umount)' "$STUB_LOG"
  [[ ${lines[0]} == "umount $MNT/docs" ]]
  [[ ${lines[1]} == "mount "* ]]
}

@test "WAIT_FOR_QUIET gives up while files keep changing" {
  echo 'QUIET_MINUTES=5
QUIET_TIMEOUT_MINUTES=0' >>"$UPB_CONFIG_DIR/upb.conf"
  touch "$STUB_EXPORTS/mnt/user/docs/letter.txt"
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs
WAIT_FOR_QUIET=true'

  run upb backup
  [ "$status" -eq 1 ]
  [[ $output == *"still changing after 0 min"* ]]
  [ -z "$(calls 'pbs backup')" ]
  [ ! -s "$STUB_MOUNTS" ]
}

@test "WAIT_FOR_QUIET proceeds when nothing changed recently" {
  echo 'QUIET_MINUTES=5
QUIET_TIMEOUT_MINUTES=0' >>"$UPB_CONFIG_DIR/upb.conf"
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs
WAIT_FOR_QUIET=true'

  run upb backup
  [ "$status" -eq 0 ]
  calls "pbs backup" | grep -q .
}

@test "config problems are all reported, and the failure is notified" {
  cat >"$UPB_CONFIG_DIR/upb.conf" <<EOF
NFS_OPTIONS="rw,hard"
PBS_AUTH_ID="root@pam"
PBS_ENCRYPTION=true
PBS_KEYFILE="$BATS_TEST_TMPDIR/missing.key"
LOCK_FILE="$BATS_TEST_TMPDIR/upb.lock"
NOTIFY_EMAIL="me@example.com"
EOF
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'

  run upb backup
  [ "$status" -eq 1 ]
  [[ $output == *"UNRAID_HOST is not set"* ]]
  [[ $output == *"NFS_OPTIONS must include 'ro'"* ]]
  [[ $output == *"PBS_DATASTORE is not set"* ]]
  [[ $output == *"must be an API token id"* ]]
  [[ $output == *"key file is missing"* ]]
  [ -z "$(calls 'mount')" ]
  [ -z "$(calls 'pbs ')" ]
  grep -qx "Subject: upb: backup did not run" "$STUB_LOG"
}

@test "invalid jobs are rejected before mounting" {
  add_job 10-bad.name.conf 'EXPORT=/mnt/user/docs'
  add_job 20-noexport.conf 'WAIT_FOR_QUIET=maybe'

  run upb backup
  [ "$status" -eq 1 ]
  [[ $output == *"[bad.name] job names"* ]]
  [[ $output == *"[noexport] EXPORT must be the absolute Unraid path"* ]]
  [[ $output == *"WAIT_FOR_QUIET must be true or false"* ]]
  [ -z "$(calls 'mount')" ]
}

@test "dry run mounts nothing and runs nothing" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs
WAIT_FOR_QUIET=true'

  run upb backup --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] mount -t nfs -o ro,soft,timeo=600,retrans=2 unraid.test:/mnt/user/docs $MNT/docs"* ]]
  [[ $output == *"[dry-run] proxmox-backup-client backup docs.pxar:$MNT/docs"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "only one backup runs at a time" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'
  exec 9>"$BATS_TEST_TMPDIR/upb.lock"
  flock 9
  run upb backup
  exec 9>&-
  [ "$status" -eq 1 ]
  [[ $output == *"already in progress"* ]]
}

@test "failures are emailed, pushed to ntfy and reported to healthchecks" {
  export STUB_PBS_EXIT=1
  cat >>"$UPB_CONFIG_DIR/upb.conf" <<'EOF'
NOTIFY_EMAIL="me@example.com"
NOTIFY_NTFY_URL="https://ntfy.test/backups"
HEALTHCHECK_URL="https://hc.test/ping/abc"
EOF
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'

  run upb backup
  [ "$status" -eq 1 ]
  grep -qx "To: me@example.com" "$STUB_LOG"
  grep -qx "Subject: upb: 1 of 1 backup job(s) failed" "$STUB_LOG"
  grep -qx "FAIL  docs (exit 1)" "$STUB_LOG"
  calls curl | grep -q -- "-H Title: upb: 1 of 1 backup job(s) failed -H Priority: high"
  grep -q "https://ntfy.test/backups$" "$STUB_LOG"
  calls curl | grep -q "https://hc.test/ping/abc/start"
  calls curl | grep -q "https://hc.test/ping/abc/fail"
}

@test "success is only notified when enabled, but always pinged" {
  cat >>"$UPB_CONFIG_DIR/upb.conf" <<'EOF'
NOTIFY_EMAIL="me@example.com"
HEALTHCHECK_URL="https://hc.test/ping/abc"
EOF
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'

  run upb backup
  [ "$status" -eq 0 ]
  [ -z "$(calls sendmail)" ]
  calls curl | grep -q "https://hc.test/ping/abc$"

  echo "NOTIFY_ON_SUCCESS=true" >>"$UPB_CONFIG_DIR/upb.conf"
  run upb backup
  grep -qx "Subject: upb: 1 backup job(s) OK" "$STUB_LOG"
}

@test "restore uses the latest snapshot of the job's group by default" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'

  run upb restore docs "$BATS_TEST_TMPDIR/restore"
  [ "$status" -eq 0 ]
  calls "pbs restore" | grep -qx "pbs restore host/unraid-docs docs.pxar $BATS_TEST_TMPDIR/restore"

  run upb restore docs "$BATS_TEST_TMPDIR/restore2" host/unraid-docs/2026-01-01T00:00:00Z
  calls "pbs restore" | grep -q "pbs restore host/unraid-docs/2026-01-01T00:00:00Z docs.pxar "
}

@test "restore refuses a non-empty target" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'
  mkdir -p "$BATS_TEST_TMPDIR/full"
  touch "$BATS_TEST_TMPDIR/full/file"
  run upb restore docs "$BATS_TEST_TMPDIR/full"
  [ "$status" -eq 1 ]
  [[ $output == *"is not empty"* ]]
  [ -z "$(calls 'pbs restore')" ]
}

@test "mount and shell open the job's archive" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'
  run upb mount docs "$BATS_TEST_TMPDIR/browse"
  [ "$status" -eq 0 ]
  calls "pbs mount" | grep -qx "pbs mount host/unraid-docs docs.pxar $BATS_TEST_TMPDIR/browse"
  run upb shell docs
  calls "pbs catalog" | grep -qx "pbs catalog shell host/unraid-docs docs.pxar"
}

@test "list shows jobs, groups and exports" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'
  add_job 20-photos.conf 'JOB_ENABLED=false
EXPORT=/mnt/user/photos'
  run upb list
  [ "$status" -eq 0 ]
  [[ ${lines[1]} == "docs"*"true"*"host/unraid-docs"*"unraid.test:/mnt/user/docs" ]]
  [[ ${lines[2]} == "photos"*"false"*"host/unraid-photos"*"unraid.test:/mnt/user/photos" ]]
}

@test "check talks to PBS and mounts every enabled export" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'
  add_job 20-empty.conf 'EXPORT=/mnt/user/empty'
  add_job 30-off.conf 'JOB_ENABLED=false
EXPORT=/mnt/user/nowhere'

  run upb check
  [ "$status" -eq 1 ]
  [[ $output == *"PBS reachable"* ]]
  [[ $output == *"NFS exports offered by unraid.test"* ]]
  [[ $output == *"job docs: ok"* ]]
  [[ $output == *"unraid.test:/mnt/user/empty is empty"* ]]
  [[ $output == *"job off: disabled"* ]]
  [ ! -s "$STUB_MOUNTS" ]
  [ -z "$(calls 'pbs backup')" ]
}

@test "the shipped example config and jobs load cleanly" {
  cp "$UPB_ROOT/config/upb.conf.example" "$UPB_CONFIG_DIR/upb.conf"
  for f in "$UPB_ROOT"/config/jobs.d/*.example; do
    cp "$f" "$UPB_CONFIG_DIR/jobs.d/$(basename "$f" .example)"
  done
  run upb list
  [ "$status" -eq 0 ]
  [[ $output == *"appdata-backup"*"true"*"host/unraid-appdata-backup"*"192.168.1.180:/mnt/user/backups/appdata"* ]]
  [[ $output == *"photos"*"false"* ]]
  [[ $output == *"documents"*"false"* ]]
}
