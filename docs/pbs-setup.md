# PBS VM side

`upb` runs on the Proxmox Backup Server VM. Each night it mounts the
Unraid shares read-only over NFS, backs each one up into the local
datastore with `proxmox-backup-client`, and unmounts them again.

## 1. Create the PBS VM

This PBS runs on a **Proxmox node**, not on Unraid. The PBS VM you already
have on Unraid (datastore on `pbs_data`) keeps backing up the Proxmox VMs;
this one backs up Unraid. Each machine's backups then live on the other
machine's disks.

1. Download the Proxmox Backup Server ISO (proxmox.com > Downloads). In
   Proxmox VE, upload it or use "Download from URL" on the node's `local`
   storage > ISO Images.
2. Create VM:
   - **OS:** the PBS ISO
   - **System:** defaults, tick *QEMU Agent*
   - **Disk 1 (system):** 32 GB on SSD-backed local storage
   - **CPU:** 2–4 cores, type `host`
   - **Memory:** 4–8 GB
   - **Network:** `vmbr0`, VirtIO
3. Before starting it, Hardware > Add > Hard Disk for the **datastore**:
   - Storage **local to the node** (local-lvm or a local ZFS pool). Never a
     storage that points back at Unraid (e.g. NFS to the `proxmox` share),
     or the backups would sit on the array they protect.
   - Size: see "How big a datastore" below.
   - Under *Advanced*: **untick "Backup"**, so the Unraid PBS doesn't copy
     the whole datastore every night, and tick **"Skip replication"**, so
     cluster replication doesn't copy it to the other node. Tick *Discard*
     and *IO thread*.
   - A whole physical disk passed through to the VM works as well.
   - General > Advanced: tick **Start at boot**.
4. Start the VM and install PBS onto the **32 GB disk**. Give it a static
   IP (the examples use `192.168.1.20`) and a hostname such as
   `pbs-unraid`.
5. In the PBS web UI (`https://192.168.1.20:8007`):
   - Administration > Repositories: disable *enterprise*, add
     *no-subscription*. Then in a shell: `apt update && apt full-upgrade -y
     && apt install -y qemu-guest-agent`.
   - Administration > Storage / Disks > Directory > Create: pick the
     datastore disk, filesystem ext4 or xfs, name `unraid`, tick *Add as
     Datastore*.

### How big a datastore

Count what PBS actually stores, not what the Unraid folders hold:

- the shares as they are (`photos_immich`, `Everything Else`, `paperless`,
  `sftpgo`, `syncthing backup`),
- **one** Appdata Backup run and **one** flash backup (`ONLY_NEWEST=1`),
  not the whole folders, which hold many old copies,

and multiply by about 1.5 for history. For this server: ~170 GB of shares
+ ~125 GB for one appdata run without Ollama and ComfyUI + ~2 GB flash ≈
300 GB, so a **500 GB** datastore disk leaves room to grow. PBS compresses and deduplicates, so
the history costs only what changes between runs. The PBS web UI shows
the real usage once the first backups are in; the disk can be grown later
(resize it in Proxmox, then grow the filesystem in the VM).

Keep the VM out of Proxmox HA, since its datastore disk is local to one
node. If the VM or the node ever dies, attach the datastore disk to a
fresh PBS install and the backups are back.

## 2. Install upb

The repository is private, so on your PC download it from GitHub
(Code > Download ZIP, or the `.tar.gz` from the branch), copy it to the VM
and unpack it:

```sh
# on your PC
scp unraid-to-proxmox-backups-*.tar.gz root@192.168.1.20:
# on the PBS VM, as root
tar xzf unraid-to-proxmox-backups-*.tar.gz
cd unraid-to-proxmox-backups-*/
bash install.sh
```

It installs `nfs-common` if needed, puts the program in `/opt/upb` with a
`upb` command in `/usr/local/bin`, creates `/etc/upb/upb.conf` and
`/etc/upb/jobs.d/*.conf` if they don't exist yet (updates never overwrite
them), and installs the `upb-backup` systemd service and timer without
enabling them. To update later, pull the new version and run
`./install.sh` again.

## 3. Prepare PBS

```sh
bash proxmox/pbs-setup.sh
# if you skipped creating the datastore in the web UI, create it here instead:
# DATASTORE_PATH=/mnt/datastore/unraid bash proxmox/pbs-setup.sh
```

| Creates | Default | Why |
|---|---|---|
| Datastore | `unraid` (only if `DATASTORE_PATH` is set) | Where the Unraid backups go |
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

`/etc/upb/jobs.d/`: one file per Unraid folder. It comes with jobs for
`Backup/appdata backup`, `Backup/flash drive backup`, `photos_immich`,
`paperless`, `Everything Else`, `sftpgo` and `syncthing backup`, all enabled.
To add one, create another file:

```bash
# /etc/upb/jobs.d/70-documents.conf  ->  job "documents", group host/unraid-documents
JOB_ENABLED=true
EXPORT="/mnt/user/documents"        # Unraid path; its share must be NFS-exported
EXCLUDES=("/cache/")                # on top of COMMON_EXCLUDES in upb.conf
WAIT_FOR_QUIET=false                # true: wait until nothing changed for QUIET_MINUTES
ONLY_NEWEST=0                       # N: only the N newest top-level entries (0 = all)
```

Share names with spaces are fine in `EXPORT`; keep them inside the quotes.

Each job becomes a backup group `host/unraid-<job>` holding one archive,
`<job>.pxar`.

## 5. Test and schedule

```sh
upb check                  # config, token, and mounts every enabled export
upb backup --dry-run       # the exact mount and client commands
upb backup flash-backup    # a small job first, to see it work end to end
upb snapshots
```

The first full run reads every share over the network, so `photos_immich`
and `Everything Else` can take hours. Later runs only read what changed.
Start it as the service, so it keeps going if your SSH session drops, and
follow the log:

```sh
systemctl start --no-block upb-backup.service
journalctl -fu upb-backup
```

Then turn on the nightly timer:

```sh
systemctl enable --now upb-backup.timer
systemctl list-timers upb-backup.timer
```

The timer runs at 06:00. Change it with `systemctl edit upb-backup.timer`:

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
