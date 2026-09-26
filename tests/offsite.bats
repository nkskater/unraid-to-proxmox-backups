#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats runs each test in a subshell

load test_helper

setup() {
  setup_upb
  OFFMNT="$BATS_TEST_TMPDIR/offmnt"
  RCLONE_OPT="-o rclone.program=$BATS_TEST_DIRNAME/stubs/rclone"
  echo "correct horse battery" >"$UPB_CONFIG_DIR/secrets/restic-password"
  echo "[gdrive]" >"$UPB_CONFIG_DIR/secrets/rclone.conf"
  cat >>"$UPB_CONFIG_DIR/upb.conf" <<EOF
OFFSITE_ENABLED=true
OFFSITE_MOUNT_ROOT="$OFFMNT"
OFFSITE_LOCK_FILE="$BATS_TEST_TMPDIR/offsite.lock"
OFFSITE_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
OFFSITE_PRUNE_WEEKDAY=""
OFFSITE_CHECK_DAY=""
EOF
}

@test "offsite copies each job from a read-only mount with restic, then applies retention" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs
EXCLUDES=("*.tmp" "/cache/")'
  add_job 20-photos.conf 'EXPORT=/mnt/user/photos'

  run upb offsite
  [ "$status" -eq 0 ]
  run grep -E '^(mount|restic|umount)' "$STUB_LOG"
  [ "${#lines[@]}" -eq 7 ]
  [ "${lines[0]}" = "mount -t nfs -o ro,soft,timeo=600,retrans=2 unraid.test:/mnt/user/docs $OFFMNT/docs" ]
  [ "${lines[1]}" = "restic $RCLONE_OPT backup --host upb --tag docs --ignore-inode --exclude \\*.tmp --exclude $OFFMNT/docs/cache/ $OFFMNT/docs" ]
  [ "${lines[2]}" = "umount $OFFMNT/docs" ]
  [ "${lines[3]}" = "mount -t nfs -o ro,soft,timeo=600,retrans=2 unraid.test:/mnt/user/photos $OFFMNT/photos" ]
  [ "${lines[4]}" = "restic $RCLONE_OPT backup --host upb --tag photos --ignore-inode $OFFMNT/photos" ]
  [ "${lines[5]}" = "umount $OFFMNT/photos" ]
  [ "${lines[6]}" = "restic $RCLONE_OPT forget --host upb --group-by host\\,tags --keep-daily 7 --keep-weekly 4 --keep-monthly 6" ]
  [ ! -s "$STUB_MOUNTS" ]
  [[ $output != *"--prune"* ]]
  [[ $output != *" check "* ]]
}

@test "the restic password stays in its file; repository and rclone config go through the environment" {
  export RESTIC_PASSWORD="from-the-caller"
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'

  run upb offsite
  [ "$status" -eq 0 ]
  grep -qx "env RESTIC_REPOSITORY=rclone:gdrive:upb-offsite RESTIC_PASSWORD_FILE=$UPB_CONFIG_DIR/secrets/restic-password RCLONE_CONFIG=$UPB_CONFIG_DIR/secrets/rclone.conf RESTIC_PACK_SIZE=64 RESTIC_PASSWORD=" "$STUB_LOG"
  run grep -c "correct horse" "$STUB_LOG"
  [ "$output" = 0 ]
}

@test "jobs choose PBS, offsite or both" {
  mkdir -p "$STUB_EXPORTS/mnt/user/pbs_data/.chunks/0000"
  echo chunk >"$STUB_EXPORTS/mnt/user/pbs_data/.chunks/0000/abcd"
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'
  add_job 20-photos.conf 'EXPORT=/mnt/user/photos
OFFSITE_BACKUP=false'
  add_job 90-pbs-data.conf 'EXPORT=/mnt/user/pbs_data
PBS_BACKUP=false'

  run upb backup
  [ "$status" -eq 0 ]
  [ "$(calls 'pbs backup' | wc -l)" -eq 2 ]
  [ "$(calls 'pbs backup' | grep -c pbs-data)" -eq 0 ]

  : >"$STUB_LOG"
  run upb offsite
  [ "$status" -eq 0 ]
  run calls "restic $RCLONE_OPT backup"
  [ "${#lines[@]}" -eq 2 ]
  [[ ${lines[0]} == *"--tag docs "* ]]
  [[ ${lines[1]} == *"--tag pbs-data --ignore-inode $OFFMNT/pbs-data" ]]

  run upb backup pbs-data
  [ "$status" -eq 1 ]
  [[ $output == *"job pbs-data is not copied to pbs"* ]]
  run upb offsite photos
  [ "$status" -eq 1 ]
  [[ $output == *"job photos is not copied to offsite"* ]]

  run upb list
  [[ ${lines[2]} == "photos"*"true"*"host/unraid-photos"*"false"*"unraid.test:/mnt/user/photos" ]]
  [[ ${lines[3]} == "pbs-data"*"true"*" - "*"true"*"unraid.test:/mnt/user/pbs_data" ]]
}

@test "a job can't turn off both destinations" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs
PBS_BACKUP=false
OFFSITE_BACKUP=false'
  run upb offsite docs
  [ "$status" -eq 1 ]
  run upb check
  [ "$status" -eq 1 ]
  [[ $output == *"both false"* ]]
}

@test "ONLY_NEWEST and anchored excludes are rewritten for restic" {
  runs="$STUB_EXPORTS/mnt/user/Backup/appdata backup"
  mkdir -p "$runs/ab_20260901" "$runs/ab_20260922" "$runs/odd[1]*"
  for d in "$runs"/*; do echo x >"$d/archive.tar"; done
  touch -d '3 hours ago' "$runs/odd[1]*" "$runs/odd[1]*/archive.tar"
  touch -d '2 hours ago' "$runs/ab_20260901" "$runs/ab_20260901/archive.tar"
  touch -d '1 hour ago' "$runs/ab_20260922" "$runs/ab_20260922/archive.tar"
  echo 'COMMON_EXCLUDES=("**/.DS_Store")' >>"$UPB_CONFIG_DIR/upb.conf"
  add_job 10-appdata-backup.conf 'EXPORT="/mnt/user/Backup/appdata backup"
ONLY_NEWEST=1'

  run upb offsite
  [ "$status" -eq 0 ]
  [[ $output == *"backing up the newest 1 of 3 entries: ab_20260922"* ]]
  run calls "restic $RCLONE_OPT backup"
  [[ $output == *'--exclude \*\*/.DS_Store '* ]]
  want="--exclude $OFFMNT/appdata-backup/"'odd\\\[1\\\]\\\*'
  [[ $output == *"$want"* ]]
  [[ $output == *"--exclude $OFFMNT/appdata-backup/ab_20260901 "* ]]
  [[ $output != *"ab_20260922"* ]]
}

@test "prune and the repository check run on their configured days, and only in full runs" {
  cat >>"$UPB_CONFIG_DIR/upb.conf" <<EOF
OFFSITE_PRUNE_WEEKDAY=$(date +%u)
OFFSITE_CHECK_DAY=$(date +%-d)
EOF
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'

  run upb offsite
  [ "$status" -eq 0 ]
  calls "restic $RCLONE_OPT forget" | grep -q -- "--keep-monthly 6 --prune$"
  calls "restic $RCLONE_OPT check --read-data-subset=5%" | grep -q .

  : >"$STUB_LOG"
  run upb offsite docs
  [ "$status" -eq 0 ]
  [ -z "$(calls "restic $RCLONE_OPT forget")" ]
  [ -z "$(calls "restic $RCLONE_OPT check")" ]
}

@test "an empty or unmounted share is never copied offsite" {
  export STUB_MOUNT_SILENT="/mnt/user/docs"
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'
  add_job 20-empty.conf 'EXPORT=/mnt/user/empty'
  mkdir -p "$OFFMNT/docs"
  echo "local file" >"$OFFMNT/docs/stray.txt"

  run upb offsite
  [ "$status" -eq 1 ]
  [[ $output == *"is not a mount point after mounting"* ]]
  [[ $output == *"is empty; refusing to back up"* ]]
  [ -z "$(calls "restic $RCLONE_OPT backup")" ]
  [ ! -s "$STUB_MOUNTS" ]
}

@test "offsite failures are notified and pinged to their own healthcheck" {
  export STUB_RESTIC_EXIT=1
  cat >>"$UPB_CONFIG_DIR/upb.conf" <<'EOF'
NOTIFY_EMAIL="me@example.com"
HEALTHCHECK_URL="https://hc.test/ping/backup"
OFFSITE_HEALTHCHECK_URL="https://hc.test/ping/offsite"
EOF
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'

  run upb offsite
  [ "$status" -eq 1 ]
  [[ $output == *"FAIL  docs (exit 1)"* ]]
  [[ $output == *"FAIL  retention (exit 1)"* ]]
  grep -qx "Subject: upb offsite: 2 of 2 step(s) failed" "$STUB_LOG"
  calls curl | grep -q "https://hc.test/ping/offsite/start"
  calls curl | grep -q "https://hc.test/ping/offsite/fail"
  [ "$(calls curl | grep -c hc.test/ping/backup)" -eq 0 ]
  [ ! -s "$STUB_MOUNTS" ]
}

@test "offsite needs OFFSITE_ENABLED and valid settings" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'
  echo "OFFSITE_ENABLED=false" >>"$UPB_CONFIG_DIR/upb.conf"
  run upb offsite
  [ "$status" -eq 1 ]
  [[ $output == *"offsite copies are off"* ]]

  cat >>"$UPB_CONFIG_DIR/upb.conf" <<EOF
OFFSITE_ENABLED=true
OFFSITE_PASSWORD_FILE="$BATS_TEST_TMPDIR/missing"
OFFSITE_MOUNT_ROOT="$MNT"
OFFSITE_PRUNE_WEEKDAY=8
NFS_OPTIONS="rw"
NOTIFY_EMAIL="me@example.com"
EOF
  run upb offsite
  [ "$status" -eq 1 ]
  [[ $output == *"offsite password file not readable"* ]]
  [[ $output == *"OFFSITE_MOUNT_ROOT must differ from MOUNT_ROOT"* ]]
  [[ $output == *"OFFSITE_PRUNE_WEEKDAY must be 1"* ]]
  [[ $output == *"NFS_OPTIONS must include 'ro'"* ]]
  grep -qx "Subject: upb offsite: did not run" "$STUB_LOG"
  [ -z "$(calls mount)" ]
  [ -z "$(calls restic)" ]
}

@test "offsite-init creates the repository only when there is none" {
  export STUB_RESTIC_NO_REPO=1
  run upb offsite-init
  [ "$status" -eq 0 ]
  calls "restic $RCLONE_OPT init" | grep -q .
  [[ $output == *"Keep a copy somewhere other than this VM"* ]]

  unset STUB_RESTIC_NO_REPO
  : >"$STUB_LOG"
  run upb offsite-init
  [ "$status" -eq 0 ]
  [[ $output == *"already exists"* ]]
  [ -z "$(calls "restic $RCLONE_OPT init")" ]
}

@test "check opens the offsite repository when offsite copies are on" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'
  run upb check
  [ "$status" -eq 0 ]
  [[ $output == *"offsite repository reachable"* ]]

  export STUB_RESTIC_NO_REPO=1
  run upb check
  [ "$status" -eq 1 ]
  [[ $output == *"cannot open the offsite repository"* ]]
}

@test "upb restic passes its arguments through" {
  run upb restic snapshots --tag docs
  [ "$status" -eq 0 ]
  calls restic | grep -qx "restic $RCLONE_OPT snapshots --tag docs"
}

@test "offsite and backup runs may overlap, but each runs only once" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'
  exec 9>"$BATS_TEST_TMPDIR/offsite.lock"
  flock 9
  run upb offsite
  offsite_status=$status
  run upb backup
  backup_status=$status
  exec 9>&-
  [ "$offsite_status" -eq 1 ]
  [ "$backup_status" -eq 0 ]
}

@test "offsite dry run mounts nothing and runs nothing" {
  add_job 10-docs.conf 'EXPORT=/mnt/user/docs'
  run upb offsite --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] mount -t nfs -o ro,soft,timeo=600,retrans=2 unraid.test:/mnt/user/docs $OFFMNT/docs"* ]]
  [[ $output == *"[dry-run] restic backup --host upb --tag docs --ignore-inode $OFFMNT/docs"* ]]
  [ ! -s "$STUB_LOG" ]
}
