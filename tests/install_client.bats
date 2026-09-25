#!/usr/bin/env bats

load test_helper

setup() {
  setup_upb
  # shellcheck source=lib/common.sh
  source "$UPB_ROOT/lib/common.sh"
  # shellcheck source=lib/install_client.sh
  source "$UPB_ROOT/lib/install_client.sh"
}

# build_deb <compression> — builds a fake client .deb and prints its path.
build_deb() {
  local pkg="$BATS_TEST_TMPDIR/pkg-$1"
  mkdir -p "$pkg/DEBIAN" "$pkg/usr/bin"
  cat >"$pkg/DEBIAN/control" <<'EOF'
Package: proxmox-backup-client-static
Version: 4.0.1-1
Architecture: amd64
Maintainer: Test <test@example.com>
Description: test package
EOF
  printf '#!/bin/sh\necho "client version: 4.0.1"\n' >"$pkg/usr/bin/proxmox-backup-client"
  chmod 0755 "$pkg/usr/bin/proxmox-backup-client"
  dpkg-deb --root-owner-group -Z"$1" --build "$pkg" "$BATS_TEST_TMPDIR/client-$1.deb" >/dev/null
  printf '%s' "$BATS_TEST_TMPDIR/client-$1.deb"
}

@test "latest_package_entry picks the newest version of the package" {
  run latest_package_entry proxmox-backup-client-static <<'EOF'
Package: proxmox-backup-client
Version: 9.9.9-1
Filename: pool/main/p/client_9.9.9.deb
SHA256: nope

Package: proxmox-backup-client-static
Version: 4.0.9-1
Filename: pool/main/p/static_4.0.9.deb
SHA256: aaa

Package: proxmox-backup-client-static
Version: 4.0.14-1
Filename: pool/main/p/static_4.0.14.deb
SHA256: bbb

Package: proxmox-backup-client-static
Version: 3.4.1-1
Filename: pool/main/p/static_3.4.1.deb
SHA256: ccc
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "4.0.14-1 pool/main/p/static_4.0.14.deb bbb" ]
}

@test "latest_package_entry fails when the package is missing" {
  run latest_package_entry proxmox-backup-client-static <<<"Package: other"
  [ "$status" -ne 0 ]
}

@test "the client is extracted from xz and gzip compressed .debs without ar" {
  command -v dpkg-deb >/dev/null || skip "dpkg-deb not installed"
  for comp in xz gzip; do
    deb=$(build_deb "$comp")
    run extract_client_from_deb "$deb" "$BATS_TEST_TMPDIR/work-$comp"
    [ "$status" -eq 0 ]
    [[ $output == */usr/bin/proxmox-backup-client ]]
    [[ $("$output" version) == "client version: 4.0.1" ]]
  done
}

@test "a file that isn't a .deb is rejected" {
  echo "not a deb" >"$BATS_TEST_TMPDIR/bogus.deb"
  run extract_client_from_deb "$BATS_TEST_TMPDIR/bogus.deb" "$BATS_TEST_TMPDIR/work"
  [ "$status" -ne 0 ]
}

@test "install-client --from copies the binary to the flash and runtime paths" {
  printf '#!/bin/sh\necho "client version: 4.0.1"\n' >"$BATS_TEST_TMPDIR/pbc"
  cat >>"$UPB_CONFIG_DIR/upb.conf" <<EOF
PBS_CLIENT_BIN="$BATS_TEST_TMPDIR/flash/bin/proxmox-backup-client"
PBS_CLIENT_RUNTIME="$BATS_TEST_TMPDIR/ram/proxmox-backup-client"
EOF
  run upb install-client --from "$BATS_TEST_TMPDIR/pbc"
  [ "$status" -eq 0 ]
  [[ $output == *"client version: 4.0.1"* ]]
  cmp "$BATS_TEST_TMPDIR/pbc" "$BATS_TEST_TMPDIR/flash/bin/proxmox-backup-client"
  [ -x "$BATS_TEST_TMPDIR/ram/proxmox-backup-client" ]
}
