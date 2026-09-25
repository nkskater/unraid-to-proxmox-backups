#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats runs each test in a subshell

load test_helper

setup() { setup_upb; }

@test "backup builds the client command for an enabled job" {
  add_job 10-docs.conf "SOURCES=(\"docs:$DATA/docs\")
EXCLUDES=(\"*.tmp\" \"/cache/\")"

  run upb backup
  [ "$status" -eq 0 ]

  run calls "pbs backup"
  [ "${#lines[@]}" -eq 1 ]
  [[ $output == "pbs backup docs.pxar:$DATA/docs --backup-type host --backup-id unraid-docs "* ]]
  [[ $output == *"--keyfile $UPB_CONFIG_DIR/secrets/encryption.key --crypt-mode encrypt"* ]]
  [[ $output == *"--change-detection-mode metadata"* ]]
  [[ $output == *'--exclude \*.tmp --exclude /cache/'* ]]
}

@test "credentials go through the environment, never the command line" {
  add_job 10-docs.conf "SOURCES=(\"docs:$DATA/docs\")"

  run upb backup
  [ "$status" -eq 0 ]
  grep -qx 'env PBS_REPOSITORY=unraid-backup@pbs!unraid@pbs.test:8007:store1 PBS_PASSWORD=s3cr3t-token PBS_FINGERPRINT=aa:bb:cc' "$STUB_LOG"
  run grep -c s3cr3t < <(calls "pbs ")
  [ "$output" = 0 ]
}

@test "namespace, no encryption and extra args are passed through" {
  cat >>"$UPB_CONFIG_DIR/upb.conf" <<'EOF'
PBS_NAMESPACE="unraid"
PBS_ENCRYPTION=false
PBS_CHANGE_DETECTION_MODE=""
PBS_EXTRA_ARGS=(--rate 10MiB)
EOF
  add_job 10-docs.conf "SOURCES=(\"docs:$DATA/docs\")
BACKUP_ID=custom-id"

  run upb backup
  [ "$status" -eq 0 ]
  run calls "pbs backup"
  [[ $output == *"--backup-id custom-id --ns unraid --crypt-mode none --rate 10MiB" ]]
  [[ $output != *--keyfile* ]]
  [[ $output != *--change-detection-mode* ]]
}

@test "disabled jobs are skipped unless named explicitly" {
  add_job 10-on.conf "SOURCES=(\"docs:$DATA/docs\")"
  add_job 20-off.conf "JOB_ENABLED=false
SOURCES=(\"photos:$DATA/photos\")"

  run upb backup
  [ "$status" -eq 0 ]
  [ "$(calls 'pbs backup' | wc -l)" -eq 1 ]
  calls "pbs backup" | grep -q -- "--backup-id unraid-on"

  : >"$STUB_LOG"
  run upb backup off
  [ "$status" -eq 0 ]
  [ "$(calls 'pbs backup' | wc -l)" -eq 1 ]
  calls "pbs backup" | grep -q -- "--backup-id unraid-off"
}

@test "an unknown job name is an error" {
  add_job 10-docs.conf "SOURCES=(\"docs:$DATA/docs\")"
  run upb backup nope
  [ "$status" -eq 1 ]
  [[ $output == *"unknown job: nope"* ]]
}

@test "a failing job doesn't stop the others, and the run reports failure" {
  add_job 10-broken.conf "SOURCES=(\"gone:$DATA/does-not-exist\")"
  add_job 20-docs.conf "SOURCES=(\"docs:$DATA/docs\")"

  run upb backup
  [ "$status" -eq 1 ]
  [[ $output == *"source directory does not exist: $DATA/does-not-exist"* ]]
  [[ $output == *"FAIL  broken"* ]]
  [[ $output == *"OK    docs"* ]]
  calls "pbs backup" | grep -q -- "--backup-id unraid-docs"
  calls "notify" | grep -q -- "-i alert"
}

@test "a success notification is only sent when enabled" {
  add_job 10-docs.conf "SOURCES=(\"docs:$DATA/docs\")"
  run upb backup
  [ -z "$(calls notify)" ]

  echo "NOTIFY_ON_SUCCESS=true" >>"$UPB_CONFIG_DIR/upb.conf"
  run upb backup
  calls notify | grep -q -- "-i normal"
}

@test "containers are stopped in order and restarted in reverse" {
  export STUB_DOCKER_RUNNING="app1 app2"
  add_job 10-docs.conf "SOURCES=(\"docs:$DATA/docs\")
STOP_CONTAINERS=(app1 app2 not-running)"
  export STUB_DOCKER_KNOWN="app1 app2 not-running"

  run upb backup
  [ "$status" -eq 0 ]
  run grep -E '^(docker (stop|start)|pbs backup)' "$STUB_LOG"
  [[ ${lines[0]} == "docker stop -t 60 app1" ]]
  [[ ${lines[1]} == "docker stop -t 60 app2" ]]
  [[ ${lines[2]} == "pbs backup"* ]]
  [[ ${lines[3]} == "docker start app2" ]]
  [[ ${lines[4]} == "docker start app1" ]]
  [ "${#lines[@]}" -eq 5 ]
}

@test "containers are restarted when the backup fails" {
  export STUB_DOCKER_RUNNING="app1" STUB_PBS_EXIT=2
  add_job 10-docs.conf "SOURCES=(\"docs:$DATA/docs\")
STOP_CONTAINERS=(app1)"

  run upb backup
  [ "$status" -eq 1 ]
  [[ $output == *"FAIL  docs (exit 2)"* ]]
  calls "docker start app1" | grep -q .
}

@test "a failing command in pre_backup skips the backup" {
  export STUB_DOCKER_RUNNING="app1"
  add_job 10-docs.conf "SOURCES=(\"docs:$DATA/docs\")
STOP_CONTAINERS=(app1)
pre_backup() {
  false
  echo 'not reached' >\"$BATS_TEST_TMPDIR/reached\"
}"

  run upb backup
  [ "$status" -eq 1 ]
  [[ $output == *"pre_backup failed"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/reached" ]
  [ -z "$(calls 'pbs backup')" ]
  [ -z "$(calls 'docker stop')" ]
}

@test "post_backup runs with the exit code even when stopping a container fails" {
  export STUB_DOCKER_RUNNING="app1 app2" STUB_DOCKER_FAIL="stop:app2"
  add_job 10-docs.conf "SOURCES=(\"docs:$DATA/docs\")
STOP_CONTAINERS=(app1 app2)
post_backup() { echo \"rc=\$1\" >\"$BATS_TEST_TMPDIR/post\"; }"

  run upb backup
  [ "$status" -eq 1 ]
  [ -z "$(calls 'pbs backup')" ]
  calls "docker start app1" | grep -q .
  [ "$(cat "$BATS_TEST_TMPDIR/post")" = "rc=1" ]
}

@test "dump_postgres writes a dump that is uploaded as the dumps archive" {
  export STUB_DOCKER_RUNNING="pg"
  add_job 20-databases.conf 'pre_backup() {
  dump_postgres pg
  dump_postgres pg app appdb
}'

  run upb backup
  [ "$status" -eq 0 ]
  dumps="$BATS_TEST_TMPDIR/staging/databases"
  [[ $(gzip -dc "$dumps/postgres-pg.sql.gz") == "-- output of: pg_dumpall --username=postgres --clean --if-exists" ]]
  [[ $(gzip -dc "$dumps/postgres-pg-appdb.sql.gz") == *"pg_dump --username=app --dbname=appdb"* ]]
  calls "pbs backup" | grep -q "pbs backup dumps.pxar:$dumps --backup-type host --backup-id unraid-databases"
}

@test "a failed dump fails the job and keeps the previous dump" {
  export STUB_DOCKER_RUNNING="pg" STUB_DOCKER_FAIL="exec:pg"
  mkdir -p "$BATS_TEST_TMPDIR/staging/databases"
  echo old | gzip >"$BATS_TEST_TMPDIR/staging/databases/postgres-pg.sql.gz"
  add_job 20-databases.conf 'pre_backup() { dump_postgres pg; }'

  run upb backup
  [ "$status" -eq 1 ]
  [ -z "$(calls 'pbs backup')" ]
  [[ $(gzip -dc "$BATS_TEST_TMPDIR/staging/databases/postgres-pg.sql.gz") == old ]]
  [ ! -e "$BATS_TEST_TMPDIR/staging/databases/postgres-pg.sql.gz.partial" ]
}

@test "a job with nothing to back up fails" {
  add_job 10-empty.conf 'SOURCES=()'
  run upb backup
  [ "$status" -eq 1 ]
  [[ $output == *"nothing to back up"* ]]
}

@test "invalid and reserved archive names are rejected" {
  add_job 10-bad.conf "SOURCES=(\"has space:$DATA/docs\" \"dumps:$DATA/photos\")"
  run upb backup
  [ "$status" -eq 1 ]
  [[ $output == *"archive name 'has space' may only contain"* ]]
  [[ $output == *"'dumps' is reserved"* ]]
  [ -z "$(calls 'pbs backup')" ]
}

@test "dry run changes nothing" {
  export STUB_DOCKER_RUNNING="app1"
  add_job 10-docs.conf "SOURCES=(\"docs:$DATA/docs\")
STOP_CONTAINERS=(app1)
pre_backup() { dump_postgres pg; }"

  run upb backup --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] proxmox-backup-client backup docs.pxar:$DATA/docs"* ]]
  [[ $output == *"[dry-run] docker stop app1"* ]]
  [ -z "$(calls 'pbs ')" ]
  [ -z "$(calls 'docker stop')" ]
  [ -z "$(calls 'docker exec')" ]
  [ ! -e "$BATS_TEST_TMPDIR/staging" ]
}

@test "config problems are all reported before anything runs" {
  cat >"$UPB_CONFIG_DIR/upb.conf" <<EOF
PBS_AUTH_ID="root@pam"
PBS_KEYFILE="$BATS_TEST_TMPDIR/missing.key"
LOCK_FILE="$BATS_TEST_TMPDIR/upb.lock"
UNRAID_NOTIFY_CMD="$BATS_TEST_DIRNAME/stubs/notify"
EOF
  add_job 10-docs.conf "SOURCES=(\"docs:$DATA/docs\")"

  run upb backup
  [ "$status" -eq 1 ]
  [[ $output == *"PBS_SERVER is not set"* ]]
  [[ $output == *"PBS_DATASTORE is not set"* ]]
  [[ $output == *"must be an API token id"* ]]
  [[ $output == *"key file is missing"* ]]
  [ -z "$(calls 'pbs ')" ]
  calls notify | grep -q -- "-i alert -s Backup did not run"
}

@test "only one backup runs at a time" {
  add_job 10-docs.conf "SOURCES=(\"docs:$DATA/docs\")"
  exec 9>"$BATS_TEST_TMPDIR/upb.lock"
  flock 9
  run upb backup
  exec 9>&-
  [ "$status" -eq 1 ]
  [[ $output == *"already in progress"* ]]
}

@test "restore uses the latest snapshot of the job's group by default" {
  add_job 10-docs.conf "SOURCES=(\"docs:$DATA/docs\")"

  run upb restore docs docs "$BATS_TEST_TMPDIR/restore"
  [ "$status" -eq 0 ]
  calls "pbs restore" | grep -qx "pbs restore host/unraid-docs docs.pxar $BATS_TEST_TMPDIR/restore --keyfile $UPB_CONFIG_DIR/secrets/encryption.key"

  run upb restore docs docs.mpxar "$BATS_TEST_TMPDIR/restore2" host/unraid-docs/2026-01-01T00:00:00Z
  calls "pbs restore" | grep -q "pbs restore host/unraid-docs/2026-01-01T00:00:00Z docs.mpxar "
}

@test "restore refuses a non-empty target" {
  add_job 10-docs.conf "SOURCES=(\"docs:$DATA/docs\")"
  touch "$DATA/docs/file"
  run upb restore docs docs "$DATA/docs"
  [ "$status" -eq 1 ]
  [[ $output == *"is not empty"* ]]
  [ -z "$(calls 'pbs restore')" ]
}

@test "list shows jobs and their groups" {
  add_job 10-docs.conf "SOURCES=(\"docs:$DATA/docs\")"
  add_job 20-databases.conf 'JOB_ENABLED=false'
  run upb list
  [ "$status" -eq 0 ]
  [[ ${lines[1]} == "docs"*"true"*"host/unraid-docs"*"docs:$DATA/docs" ]]
  [[ ${lines[2]} == "databases"*"false"*"host/unraid-databases"*"(dumps only)" ]]
}

@test "check validates jobs and talks to the server" {
  add_job 10-docs.conf "SOURCES=(\"docs:$DATA/docs\")"
  run upb check
  [ "$status" -eq 0 ]
  [[ $output == *"PBS reachable"* ]]
  [[ $output == *"job docs: ok"* ]]
  calls "pbs version" | grep -q .
}

@test "the shipped example config and jobs load cleanly" {
  cp "$UPB_ROOT/config/upb.conf.example" "$UPB_CONFIG_DIR/upb.conf"
  for f in "$UPB_ROOT"/config/jobs.d/*.example; do
    cp "$f" "$UPB_CONFIG_DIR/jobs.d/$(basename "$f" .example)"
  done
  run upb list
  [ "$status" -eq 0 ]
  [[ $output == *"flash"*"true"*"host/unraid-flash"*"flash:/boot"* ]]
  [[ $output == *"immich"*"false"* ]]
}
