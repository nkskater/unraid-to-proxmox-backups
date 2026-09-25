# unraid-to-proxmox-backups

Bash tool (`upb`) that backs up Unraid data to Proxmox Backup Server with
`proxmox-backup-client`.

- Run `make check` (shellcheck + bats) before committing. Tests use stubs in
  `tests/stubs/` for docker, the client and Unraid's notify script.
- Unraid constraints: the root filesystem is RAM, `/boot` (flash, FAT32)
  persists but can't execute binaries, and there's no dpkg/apt/python and
  often no jq/ar/git. Stick to bash 5 + coreutils/util-linux + curl/tar/xz.
- Config and job files are sourced bash. Never add anything that deletes
  directories derived from user config.
- Credentials reach the client only through environment variables
  (`pbs_client` in `lib/pbs.sh`), never argv.
- Hooks run in `( set -e; hook )` subshells; `run_job` must never be called
  from an `if`/`&&`/`||` context or `set -e` stops working inside hooks.
