# PBS VM side

`upb` runs on the Proxmox Backup Server VM. Each night it mounts the
Unraid shares read-only over NFS, backs each one up into the local
datastore with `proxmox-backup-client`, and unmounts them again.

## 1. The PBS VM

- **Datastore disk:** give the datastore its own virtual disk (or a
  passed-through disk), separate from the VM's system disk. If the VM or
  the cluster ever dies, attach that disk to a fresh PBS install and the
  backups are back. Size it at roughly 1.5–2× the data you back up.
- **Fixed IP:** the Unraid NFS rules allow exactly this address.
- **Don't back up the PBS VM with itself.** If you back up VMs from Proxmox
  VE to this PBS, exclude the PBS VM, or at least its datastore disk.

## 2. Install upb

Copy this repository to the VM (`git clone`, or `scp` a download), then as
root:

```sh
cd unraid-to-proxmox-backups
./install.sh
```

It installs `nfs-common` if needed, puts the program in `/opt/upb` with a
`upb` command in `/usr/local/bin`, creates `/etc/upb/upb.conf` and
`/etc/upb/jobs.d/*.conf` if they don't exist yet (updates never overwrite
them), and installs the `upb-backup` systemd service and timer without
enabling them. To update later, pull the new version and run
`./install.sh` again.

## 3. Prepare PBS

```sh
# creates the datastore too, if it doesn't exist yet
DATASTORE_PATH=/mnt/datastore/unraid ./proxmox/pbs-setup.sh
```

| Creates | Default | Why |
|---|---|---|
| Datastore | `unraid` | Keeps Unraid data apart from VM backups |
| User + API token | `unraid-backup@pbs!unraid` | What upb logs in with; the secret is written to `/etc/upb/secrets/pbs-token` |
| ACL | `DatastoreBackup` on `/datastore/unraid` | Can add backups, **can't delete or prune** them |
| Prune job | daily 08:00: keep 3 last, 14 daily, 8 weekly, 12 monthly, 3 yearly | Retention, run by PBS |
| Garbage collection | daily 09:00 | Frees chunks that pruned snapshots no longer use |
| Verify job | Saturday 10:00, re-verify after 30 days | Detects bit rot and disk problems |

It also writes the certificate fingerprint into `/etc/upb/upb.conf`.
Everything can be changed with environment variables, e.g.
`KEEP_DAILY=30 DATASTORE=main ./proxmox/pbs-setup.sh`. See the top of the
script. Re-running it is safe.

## 4. Configure

`/etc/upb/upb.conf`: check `UNRAID_HOST` (`192.168.1.180`) and set a
notification method (below).

`/etc/upb/jobs.d/`: one file per Unraid folder.

- `10-appdata-backup.conf`: set `EXPORT` to the Appdata Backup destination.
  Enabled.
- `20-photos.conf`: the Immich library. Check `EXPORT`, then set
  `JOB_ENABLED=true`.
- `90-documents.conf`: copy it once per extra share.

A job file looks like this:

```bash
JOB_ENABLED=true
EXPORT="/mnt/user/photos"        # Unraid path; its share must be NFS-exported
EXCLUDES=("/thumbs/" "/encoded-video/")
WAIT_FOR_QUIET=false             # true: wait until nothing changed for QUIET_MINUTES
```

Each job becomes a backup group `host/unraid-<job>` holding one archive,
`<job>.pxar`.

## 5. Test and schedule

```sh
upb check              # config, token, and mounts every enabled export
upb backup --dry-run   # the exact mount and client commands
upb backup             # first run: reads everything, later runs only changes
upb snapshots

systemctl enable --now upb-backup.timer
systemctl list-timers upb-backup.timer
```

The timer runs at 05:00. Change it with `systemctl edit upb-backup.timer`:

```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 06:30
```

## Notifications

Set at least one in `upb.conf`:

- `NOTIFY_EMAIL`: sent through the VM's `sendmail` (postfix). Check
  that postfix can deliver: `echo test | mail -s test you@example.com`.
- `NOTIFY_NTFY_URL`: push notification through ntfy.
- `HEALTHCHECK_URL`: healthchecks.io or compatible. The only option that
  also tells you when a backup **didn't run at all** (VM down, timer broken).

Logs: `journalctl -u upb-backup` and `/var/log/upb/`.

## Encryption

Off by default. The key would live on this VM next to the datastore, so it
protects little here, and unencrypted backups can be browsed and downloaded
in the PBS web UI. If you later sync the datastore off site, run
`upb init-key`, keep the printed paper key somewhere safe, and set
`PBS_ENCRYPTION=true`. New snapshots are encrypted from then on.

## Optional: offsite copy

A second PBS elsewhere can **pull** this datastore with a sync job. PBS 4
can also use S3-compatible storage as a datastore backend.
