# Offsite copy to Google Drive

`upb offsite` runs on the PBS VM after the nightly PBS backup. It mounts the
same Unraid shares read-only again and copies them to Google Drive with
**restic**, which talks to Drive through **rclone**:

- restic encrypts everything on the VM before it's uploaded. Google only
  stores scrambled files.
- It deduplicates and only uploads what changed since the last run.
- It keeps its own snapshots: by default 7 daily, 4 weekly and 6 monthly per
  job.
- The copy doesn't depend on PBS. Any computer with restic, rclone and the
  password can restore from it, one file or everything.

What goes up:

| What | From |
|---|---|
| The Unraid jobs (appdata, flash, photos, paperless, …) | Every enabled job in `/etc/upb/jobs.d/`. A job can opt out with `OFFSITE_BACKUP=false` |
| Your Proxmox VM backups and the Proxmox nodes' configuration | The `pbs-data` job: the datastore of the PBS on Unraid (`pbs_data` share). Off until you turn it on, see [below](#proxmox-vm-backups-pbs-data) |

Why restic and not a copy of PBS's datastore: a PBS datastore is tens of
thousands of small files, Google Drive only accepts about 2 new files per
second, and restoring anything from such a copy means downloading all of it
into a PBS first. restic packs data into larger files and restores single
files anywhere. (The `pbs-data` job does copy a whole datastore, but through
restic, which keeps nightly versions of it.)

## Before you start

- **Drive space.** About 150 GB for the Unraid jobs, plus the size of
  `pbs_data` (`du -sh /mnt/user/pbs_data` on Unraid), plus room for history.
- **Upload time.** The first upload sends everything. Your upload speed sets
  the pace: at 50 Mbit/s that's about 20 GB an hour. Google also caps uploads
  at 750 GB per day. After that, only changes go up.
- **The password.** restic's password is the one thing you must never lose:
  without it the Drive copy can't be read, by you or anyone else.
- **upb 0.2.0 or newer** on the PBS VM ([updating](pbs-setup.md#updating)).

## 1. Install restic and rclone (PBS VM)

```sh
apt install -y restic
curl https://rclone.org/install.sh | bash   # the newest rclone; Debian's package is older
```

## 2. Connect Google Drive

The VM has no browser, so you sign in to Google on your PC. Download rclone
for your PC from <https://rclone.org/downloads/> and unzip it.

On the VM:

```sh
rclone config --config /etc/upb/secrets/rclone.conf
```

Answer the questions:

| Question | Answer |
|---|---|
| New remote / name | `n`, then `gdrive` |
| Storage | `drive` (Google Drive) |
| client_id, client_secret | Enter (empty) |
| scope | `drive.file`: rclone can only see the files it creates, not the rest of your Drive |
| service_account_file | Enter |
| Edit advanced config | `n` |
| Use web browser to automatically authenticate | **`n`** |

rclone now prints a command like `rclone authorize "drive" "eyJ..."`. Run it
on your PC, in the folder where you unzipped rclone (on Windows:
`.\rclone.exe authorize "drive" "eyJ..."`). A browser opens: sign in to
Google and allow access. The PC then prints a token: paste it at the VM's
`config_token>` prompt. Answer `n` to Shared Drive, `y` to keep the remote,
`q` to quit.

Then:

```sh
chmod 600 /etc/upb/secrets/rclone.conf
rclone --config /etc/upb/secrets/rclone.conf mkdir gdrive:upb-offsite
rclone --config /etc/upb/secrets/rclone.conf lsd gdrive:   # shows upb-offsite
```

A folder `upb-offsite` now exists in your Google Drive. Leave it alone: its
contents are restic's encrypted files.

## 3. Password and repository

Create the password and **copy it into your password manager right away**:

```sh
(umask 077; openssl rand -base64 32 > /etc/upb/secrets/restic-password)
cat /etc/upb/secrets/restic-password
```

Turn offsite copies on by adding this line to `/etc/upb/upb.conf` (updates
never change that file, so it doesn't have the new settings yet; every other
offsite setting has a default, see `config/upb.conf.example`):

```bash
OFFSITE_ENABLED=true
```

Optional, to keep the upload from filling your internet connection (about
4 MB/s):

```bash
OFFSITE_EXTRA_ARGS=(--limit-upload 4000)
```

Create the repository on Drive and check everything:

```sh
upb offsite-init
upb check      # ends with "offsite repository reachable" and "all checks passed"
```

## 4. First upload

Start it as the service, so it keeps going if your SSH session drops:

```sh
systemctl start --no-block upb-offsite.service
journalctl -fu upb-offsite        # Ctrl+C stops watching, not the upload
```

restic prints a progress line every minute. The first upload can take a day
or more. While it runs, the nightly PBS backup keeps working: they use
separate mount points and locks.

## 5. Schedule

```sh
systemctl enable --now upb-offsite.timer
systemctl list-timers upb-offsite.timer
```

It runs daily at 10:30, after the 06:00 PBS backup and PBS's prune and garbage
collection. If a run is still going (the first upload), the next one waits
for the following day. Change the time with `systemctl edit upb-offsite.timer`:

```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 11:30
```

Failures are notified like backups (email, ntfy). For healthchecks.io, create
a **second** check for offsite runs and put its URL in
`OFFSITE_HEALTHCHECK_URL`, with a grace time of a day or two so the first
upload doesn't count as missed.

## Proxmox VM backups (pbs-data)

The job `90-pbs-data.conf` copies the datastore of the PBS on Unraid: your
Proxmox VM backups and, with [upb host-backup](pve-host-backup.md), the
nodes' configuration. It's only copied offsite, not into this PBS.

1. **Size.** `du -sh /mnt/user/pbs_data` on Unraid. Make sure Drive has room.
2. **Access.** The PBS VM must be able to read the share. It's currently
   exported to everyone (`*`), which is enough: `showmount -e 192.168.1.180`
   lists `/mnt/user/pbs_data`. If you restrict that export later, keep the
   entry the PBS on Unraid uses and add `192.168.1.20(ro,sec=sys,no_root_squash)`.
3. **Turn it on.** In `/etc/upb/jobs.d/90-pbs-data.conf` set
   `JOB_ENABLED=true`. `upb check` must show `job pbs-data: ok`.
4. **Timing.** The copy is only consistent while the PBS on Unraid isn't
   writing. The job waits until nothing changed for 10 minutes, but pick an
   offsite time outside that PBS's busy hours: Proxmox VE → Datacenter →
   Backup (when VM backups run), and the PBS on Unraid → Datastore → Prune &
   GC. A VM backup that starts while the copy runs may be incomplete in that
   night's copy; the next night's copy has it. Backups that finished before
   the copy started are always complete.
5. **Test it alone** (the first run uploads the whole datastore):
   `upb offsite pbs-data`.

## Restoring from Google Drive

### From the PBS VM

```sh
upb restic snapshots                         # everything; the tag is the job name
upb restic ls latest --tag paperless         # the files in the newest paperless copy
upb restic restore latest --tag paperless --target /mnt/restore
```

Files land under `/mnt/restore/mnt/upb-offsite/paperless/`. To restore one
file or folder, add `--include` with its path as `ls` shows it. Copy the
result back to Unraid with rsync, as in [restore.md](restore.md).

### From any computer, if the VM is gone

1. Install restic and rclone (Linux, Windows or macOS).
2. `rclone config`: create the `gdrive` remote as above, but choose scope
   **`drive`** (full access), so rclone sees the folder no matter which
   machine created it.
3. Point restic at it; it asks for the password:
   ```sh
   export RESTIC_REPOSITORY=rclone:gdrive:upb-offsite
   restic snapshots
   restic restore latest --tag photos-immich --target /restore
   ```

### The whole pbs_data datastore

```sh
restic -r rclone:gdrive:upb-offsite restore latest --tag pbs-data --target /restore
```

`/restore/mnt/upb-offsite/pbs-data/` is then the datastore folder (the one
with `.chunks`). On a new or rebuilt PBS:

1. Move that folder onto the disk the datastore will live on, e.g.
   `/mnt/datastore/pbs_data`, and `chown -R backup:backup` it.
2. PBS web UI → Datastore → Add Datastore, with that path; reuse the existing
   datastore.
3. In Proxmox VE, add that PBS as storage and restore VMs as usual. The
   nodes' configuration is in the namespace `pve-hosts`.

With restic 0.17 or newer, `restore latest:/mnt/upb-offsite/pbs-data --target
/mnt/datastore/pbs_data` skips the extra folder levels.

## Everyday commands

| Command | Does |
|---|---|
| `upb offsite` | Copy all enabled jobs, then apply retention |
| `upb offsite photos-immich` | Copy one job (no retention run) |
| `upb offsite --dry-run` | Show what would run |
| `upb restic snapshots` | List the offsite snapshots |
| `upb restic stats --mode raw-data` | How much space the copy takes on Drive |
| `upb restic check` | Verify the repository's structure (add `--read-data` to download and check everything) |

## Troubleshooting

| Problem | Fix |
|---|---|
| `repository is already locked` | A run was interrupted. Check that no `upb offsite` is running, then `upb restic unlock` |
| `rateLimitExceeded`, very slow uploads | rclone's shared Google client is busy. Make your own client ID (<https://rclone.org/drive/#making-your-own-client-id>), enter it in `rclone config`, and use the same one when restoring |
| `token expired` / `invalid_grant` | The Google sign-in was revoked, e.g. after a password change: `rclone config reconnect gdrive: --config /etc/upb/secrets/rclone.conf` |
| Drive full | Uploads fail. Get more space, or lower `OFFSITE_KEEP_*` (space is freed on the next `OFFSITE_PRUNE_WEEKDAY`) |
| A job no longer goes offsite | Its old snapshots stay. List them with `upb restic snapshots --tag JOB`, then `upb restic forget ID... --prune` |

## Security notes

- The VM holds both the Drive login and the password, so whoever controls the
  VM can read or delete the offsite copy. Files deleted on Drive stay in its
  trash for 30 days.
- restic's password never appears on a command line: upb passes the path of
  the password file in the environment.
