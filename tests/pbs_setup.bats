#!/usr/bin/env bats

load test_helper

setup() {
  setup_upb
  export UPB_CONF="$BATS_TEST_TMPDIR/etc/upb.conf"
  export TOKEN_FILE="$BATS_TEST_TMPDIR/etc/secrets/pbs-token"
  mkdir -p "$(dirname "$UPB_CONF")"
  cp "$UPB_ROOT/config/upb.conf.example" "$UPB_CONF"
}

pbs_setup() { bash "$UPB_ROOT/proxmox/pbs-setup.sh"; }

@test "a fresh PBS gets datastore, user, token, ACLs and schedules" {
  DATASTORE_PATH=/mnt/ds run pbs_setup
  [ "$status" -eq 0 ]
  calls pbm | grep -qx "pbm datastore create unraid /mnt/ds --comment Unraid backups (upb)"
  calls pbm | grep -qx "pbm user create unraid-backup@pbs --comment Unraid backups (upb)"
  calls pbm | grep -qx "pbm user generate-token unraid-backup@pbs unraid"
  calls pbm | grep -qx "pbm acl update /datastore/unraid DatastoreBackup --auth-id unraid-backup@pbs"
  calls pbm | grep -qx "pbm acl update /datastore/unraid DatastoreBackup --auth-id unraid-backup@pbs!unraid"
  calls pbm | grep -q "^pbm prune-job create unraid-retention --store unraid --schedule 08:00 --keep-last 3 --keep-daily 14"
  calls pbm | grep -q "^pbm verify-job create unraid-verify --store unraid --schedule sat 10:00"
}

@test "the token secret and fingerprint are written into upb's config" {
  DATASTORE_PATH=/mnt/ds run pbs_setup
  [ "$status" -eq 0 ]
  [ "$(cat "$TOKEN_FILE")" = "0123-abcd-secret" ]
  [ "$(stat -c %a "$TOKEN_FILE")" = 600 ]
  grep -qx 'PBS_FINGERPRINT="64:d3:ff:3a"' "$UPB_CONF"
}

@test "re-running keeps existing objects and updates the schedules" {
  export STUB_PBM_EXISTING=1
  run pbs_setup
  [ "$status" -eq 0 ]
  [ -z "$(calls 'pbm datastore create')" ]
  [ -z "$(calls 'pbm user create')" ]
  [ -z "$(calls 'pbm user generate-token')" ]
  [ ! -e "$TOKEN_FILE" ]
  calls pbm | grep -q "^pbm prune-job update unraid-retention --schedule 08:00"
  calls pbm | grep -q "^pbm verify-job update unraid-verify --schedule sat 10:00"
}

@test "a missing datastore without DATASTORE_PATH is an error" {
  run pbs_setup
  [ "$status" -eq 1 ]
  [[ $output == *"datastore 'unraid' doesn't exist"* ]]
  [ -z "$(calls 'pbm user')" ]
}
