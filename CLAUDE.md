# unraid-to-proxmox-backups

`upb` runs on a Proxmox Backup Server VM and pulls Unraid shares into PBS:
it mounts each share read-only over NFS and runs `proxmox-backup-client`.
Nothing runs on Unraid; its side is configuration (Appdata Backup plugin +
NFS exports), documented in `docs/unraid-setup.md`.

Two optional parts share the code: `upb offsite` (lib/offsite.sh) copies the
same jobs with restic, via rclone to Google Drive (`docs/offsite.md`), and
`upb host-backup` (lib/host.sh) runs on Proxmox VE nodes, installed with
`install.sh --pve-host`, backing up their configuration (`docs/pve-host-backup.md`).

- Run `make check` (shellcheck + bats) before committing. Tests use stubs in
  `tests/stubs/` for mount/umount/mountpoint, the client, the PBS manager,
  restic, rclone, sqlite3, sendmail and curl; the mount stub serves a fake
  Unraid from `$STUB_EXPORTS`. CI runs shellcheck 0.9.0 and bats 1.10.0.
- Target: Debian (PBS, Proxmox VE), bash 5, coreutils, util-linux,
  nfs-common, curl; restic/rclone for offsite, sqlite3 on PVE nodes.
  No jq or python.
- Safety invariants, each covered by a test: NFS options must include `ro`;
  a job never backs up a path that isn't a freshly mounted, non-empty share
  (PBS or offsite); shares are always unmounted (EXIT trap set by
  `open_job_source`, and in `check_job`); host backups refuse an empty
  `/etc/pve`.
- Config and job files are sourced bash. Never add anything that deletes
  directories derived from user config.
- Credentials reach the clients only through environment variables
  (`pbs_client` in `lib/pbs.sh`, `restic_run` in `lib/offsite.sh`, which
  passes the password *file*), never argv.
