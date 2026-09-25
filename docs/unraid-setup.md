# Unraid side

Prerequisites: Unraid 6.12 or newer (developed against 7.2), the **User
Scripts** plugin from Community Applications, and a PBS prepared as in
[proxmox-setup.md](proxmox-setup.md).

## 1. Install

Get this repository onto the server, into any folder on a share. Either
`git clone` it (if git is installed), or download the ZIP from GitHub and copy
it to e.g. `\\tower\system\unraid-to-proxmox-backups`. Then, in the Unraid
terminal:

```sh
cd /mnt/user/system/unraid-to-proxmox-backups
bash install.sh
```

The installer:

- copies the program to `/boot/config/upb/app/`
- creates `/boot/config/upb/upb.conf` and the job files in
  `/boot/config/upb/jobs.d/` **only if they don't exist yet**, so updates
  never overwrite your settings
- adds the `upb` command (`/usr/local/bin/upb`, in RAM, recreated by each
  scheduled run)
- installs the `upb-backup` User Script
- downloads the static `proxmox-backup-client` from download.proxmox.com

To update later, get the new version of the repo and run `bash install.sh`
again.

### If the client download fails

Download the `proxmox-backup-client-static` package (`.deb`, amd64) from
<https://download.proxmox.com/debian/pbs-client/> on another machine, copy
it to the server, and run:

```sh
upb install-client --from /mnt/user/system/proxmox-backup-client-static_*.deb
```

## 2. Configure

Everything lives on the flash drive, in `/boot/config/upb/`:

```
upb.conf                 connection, encryption, notifications
jobs.d/NN-name.conf      one file per backup job
secrets/pbs-token        API token secret (from pbs-setup.sh)
secrets/encryption.key   created by `upb init-key`
bin/proxmox-backup-client
app/                     the program (replaced on update)
```

1. Fill in `PBS_SERVER`, `PBS_DATASTORE`, `PBS_AUTH_ID` and
   `PBS_FINGERPRINT` in `upb.conf` (pbs-setup.sh printed them).
2. Save the token secret:
   ```sh
   echo 'the-token-secret' > /boot/config/upb/secrets/pbs-token
   ```
3. Create the encryption key and **store the paper copy it prints somewhere
   safe, off this server** (a password manager is fine):
   ```sh
   upb init-key
   ```
4. Review the jobs in `jobs.d/`. `flash`, `databases` and `appdata` are on by
   default. Enable `immich`, `paperless` and `shares` once their paths match
   your containers (Docker tab > container > Edit shows the host paths).
   Disable a job with `JOB_ENABLED=false`, or delete the file.

## 3. Test

```sh
upb check              # config, token, connection, every job's paths
upb list               # what will be backed up
upb backup --dry-run   # the exact client commands, without running them
upb backup             # the real thing; the first run is a full upload
upb snapshots          # see what's on PBS now
```

Logs go to `/var/log/upb/` (RAM). Set `LOG_DIR` in `upb.conf` to keep them
on a share.

## 4. Schedule

Settings > User Scripts > `upb-backup` > schedule **Custom** `0 3 * * *`
(03:00 daily, before the PBS prune job at 06:00).

The script skips runs while a parity check is going (`#noParity=true` in its
header). If you set `HEALTHCHECK_URL`, a skipped or failed run also raises an
alert there.

## Container consistency

- **Postgres**: dumped live with `pg_dump` by the `databases` job. Set the
  user in `20-databases.conf` if a container's `POSTGRES_USER` isn't
  `postgres`.
- **SQLite apps** (the *arr apps, Home Assistant, Plex, …): a live copy is
  usually fine, and most of these apps write their own periodic backups into
  appdata anyway. For a guaranteed clean copy, list them in
  `STOP_CONTAINERS` in `30-appdata.conf`. They're stopped just for that job
  and always started again, even when the backup fails.

## Uninstall

Delete the `upb-backup` User Script and `/boot/config/upb/`. Keep a copy of
`secrets/encryption.key` for as long as you might need the old backups.
