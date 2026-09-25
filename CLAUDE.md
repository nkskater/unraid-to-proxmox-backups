# unraid-to-proxmox-backups

`upb` runs on a Proxmox Backup Server VM and pulls Unraid shares into PBS:
it mounts each share read-only over NFS and runs `proxmox-backup-client`.
Nothing runs on Unraid; its side is configuration (Appdata Backup plugin +
NFS exports), documented in `docs/unraid-setup.md`.

- Run `make check` (shellcheck + bats) before committing. Tests use stubs in
  `tests/stubs/` for mount/umount/mountpoint, the client, the PBS manager,
  sendmail and curl; the mount stub serves a fake Unraid from `$STUB_EXPORTS`.
- Target: Debian (PBS), bash 5, coreutils, util-linux, nfs-common, curl.
  No jq or python.
- Safety invariants, each covered by a test: NFS options must include `ro`;
  a job never backs up a path that isn't a freshly mounted, non-empty share;
  shares are always unmounted (EXIT trap in `run_job`/`check_job`).
- Config and job files are sourced bash. Never add anything that deletes
  directories derived from user config.
- Credentials reach the client only through environment variables
  (`pbs_client` in `lib/pbs.sh`), never argv.
