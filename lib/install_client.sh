# shellcheck shell=bash
# Installs the statically linked proxmox-backup-client on Unraid.
#
# Proxmox publishes it as the Debian package proxmox-backup-client-static.
# Unraid has no dpkg (and often no `ar`), so the .deb is unpacked by hand.

PBS_STATIC_PACKAGE=proxmox-backup-client-static

# fetch_package_index <mirror> <dist> — prints the amd64 Packages index.
fetch_package_index() {
  local base="$1/dists/$2/main/binary-amd64"
  curl -fsSL --retry 2 "$base/Packages" 2>/dev/null ||
    curl -fsSL --retry 2 "$base/Packages.gz" | gzip -dc 2>/dev/null
}

# latest_package_entry <package> — reads a Packages index on stdin and prints
# "<version> <filename> <sha256>" for the newest version of the package.
latest_package_entry() {
  awk -v pkg="$1" '
    function flush() {
      if (name == pkg && file != "" && sha != "") print ver, file, sha
      name = ver = file = sha = ""
    }
    /^Package: / { name = $2 }
    /^Version: / { ver = $2 }
    /^Filename: / { file = $2 }
    /^SHA256: / { sha = $2 }
    /^$/ { flush() }
    END { flush() }
  ' | sort -V -k1,1 | tail -n 1 | grep .
}

# download_static_client <out.deb>
download_static_client() {
  local out=$1 dist entry version file sha
  local -a dists=("$PBS_CLIENT_DIST")
  [[ $PBS_CLIENT_DIST != bookworm ]] && dists+=(bookworm)
  for dist in "${dists[@]}"; do
    info "looking up $PBS_STATIC_PACKAGE in $PBS_CLIENT_MIRROR ($dist)"
    entry=$(fetch_package_index "$PBS_CLIENT_MIRROR" "$dist" | latest_package_entry "$PBS_STATIC_PACKAGE") || continue
    read -r version file sha <<<"$entry"
    info "downloading $PBS_STATIC_PACKAGE $version"
    curl -fsSL --retry 3 -o "$out" "$PBS_CLIENT_MIRROR/$file" || return 1
    if [[ $(sha256sum "$out" | cut -d' ' -f1) != "$sha" ]]; then
      error "checksum mismatch for $file"
      return 1
    fi
    return 0
  done
  error "$PBS_STATIC_PACKAGE not found in $PBS_CLIENT_MIRROR"
  return 1
}

# deb_extract_data_tar <file.deb> <out-dir> — extracts the data.tar.* member of
# the ar archive and prints its path.
deb_extract_data_tar() {
  local deb=$1 out=$2 offset=8 total header name size
  if [[ $(head -c 7 "$deb") != '!<arch>' ]]; then
    error "$deb is not a .deb file"
    return 1
  fi
  total=$(stat -c %s "$deb")
  while ((offset + 60 <= total)); do
    # ar member header: name[16] mtime[12] uid[6] gid[6] mode[8] size[10] magic[2]
    header=$(dd if="$deb" bs=1 skip="$offset" count=60 status=none)
    name=${header:0:16}
    name=${name%%[[:space:]]*}
    name=${name%/}
    size=${header:48:10}
    size=${size//[[:space:]]/}
    if [[ ! $size =~ ^[0-9]+$ ]]; then
      error "corrupt archive header in $deb"
      return 1
    fi
    offset=$((offset + 60))
    if [[ $name == data.tar* ]]; then
      dd if="$deb" of="$out/$name" bs=64K iflag=skip_bytes,count_bytes \
        skip="$offset" count="$size" status=none || return 1
      printf '%s' "$out/$name"
      return 0
    fi
    offset=$((offset + size + size % 2))
  done
  error "no data.tar member in $deb"
  return 1
}

# extract_client_from_deb <file.deb> <work-dir> — prints the path of the binary.
extract_client_from_deb() {
  local deb=$1 dir=$2 data bin
  mkdir -p "$dir/root" || return 1
  data=$(deb_extract_data_tar "$deb" "$dir") || return 1
  case $data in
    *.tar.xz) tar -xJf "$data" -C "$dir/root" ;;
    *.tar.zst) zstd -dcq "$data" | tar -xf - -C "$dir/root" ;;
    *.tar.gz) tar -xzf "$data" -C "$dir/root" ;;
    *.tar) tar -xf "$data" -C "$dir/root" ;;
    *)
      error "unsupported archive in .deb: $(basename "$data")"
      false
      ;;
  esac || return 1
  bin=$(find "$dir/root" -type f -name proxmox-backup-client -print -quit)
  [[ -n $bin ]] || bin=$(find "$dir/root" -type f -path '*/bin/proxmox-backup-client*' -print -quit)
  [[ -n $bin ]] || return 1
  printf '%s' "$bin"
}

cmd_install_client() {
  local from="" deb="" bin="" version
  while (($#)); do
    case $1 in
      --from)
        from=${2:?--from needs a file}
        shift 2
        ;;
      *) die "unknown option: $1" ;;
    esac
  done
  load_config optional

  UPB_TMP=$(mktemp -d) || die "cannot create a temporary directory"
  trap 'rm -rf -- "$UPB_TMP"' EXIT

  if [[ -n $from ]]; then
    [[ -r $from ]] || die "cannot read $from"
    case $from in
      *.deb) deb=$from ;;
      *) bin=$from ;;
    esac
  else
    deb="$UPB_TMP/client.deb"
    download_static_client "$deb" ||
      die "download failed. Download the $PBS_STATIC_PACKAGE .deb yourself and run: upb install-client --from <file.deb>"
  fi
  if [[ -n $deb ]]; then
    bin=$(extract_client_from_deb "$deb" "$UPB_TMP/pkg") || die "proxmox-backup-client not found in $deb"
  fi

  install -m 0755 "$bin" "$UPB_TMP/proxmox-backup-client" || die "cannot copy $bin"
  version=$("$UPB_TMP/proxmox-backup-client" version 2>&1) || die "the client does not run on this system: $version"

  mkdir -p "$(dirname "$PBS_CLIENT_BIN")" || die "cannot create $(dirname "$PBS_CLIENT_BIN")"
  cp -f "$UPB_TMP/proxmox-backup-client" "$PBS_CLIENT_BIN" || die "cannot write $PBS_CLIENT_BIN"
  ensure_client || die "cannot install the client to $PBS_CLIENT_RUNTIME"
  info "installed $PBS_CLIENT_BIN ($version)"
}
