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
+ ~40 GB for one appdata run (after the exclusions) + ~2 GB flash ≈
210 GB, so a **400–500 GB** datastore disk leaves plenty of room to grow. PBS compresses and deduplicates, so
the history costs only what changes between runs. The PBS web UI shows
the real usage once the first backups are in; the disk can be grown later
(resize it in Proxmox, then grow the filesystem in the VM).

### Growing the datastore later

Keep an eye on the usage on the PBS dashboard and grow the disk before it
passes ~80%: a full datastore stops accepting backups, and garbage
collection needs some free space to run.

1. Proxmox VE: VM > Hardware > the datastore disk > Disk Action > Resize,
   and add the extra GB.
2. In the PBS VM's shell, find the datastore's partition, e.g. `/dev/sdb1`:
   `findmnt -no SOURCE /mnt/datastore/unraid`. Then grow it (here for
   `/dev/sdb1`):
   ```sh
   apt install -y cloud-guest-utils   # once, for growpart
   growpart /dev/sdb 1
   resize2fs /dev/sdb1                # works while mounted
   ```
3. The datastore shows the new size right away.

### Making the datastore disk smaller

Proxmox can only grow disks. Before moving to a smaller one, check whether
the big one really takes that space: on a ZFS pool, a disk is either *thin*
(takes only what's written) or *thick* (reserves its full size). On the
Proxmox node:

```sh
zfs list -t volume -o name,volsize,used,refreservation | grep vm-<vmid>-
```

- `refreservation` is `none`: the disk is thin and already takes only what
  PBS wrote. A smaller disk saves nothing; just keep an eye on the pool.
- `refreservation` is about the disk's size: it's thick. `zfs set
  refreservation=none <name>` (the name from the list) gives the unused part
  back to the pool right away, with no copying. The pool can then run full
  before the disk does, so watch the pool's usage. To make new disks thin:
  Datacenter > Storage > the ZFS storage > Edit > Thin provision.

With thin disks, PBS's garbage collection only returns space to the pool if
the VM trims: `systemctl enable --now fstrim.timer` in the PBS VM.

To really move to a smaller disk (pick a size that keeps usage under ~60%;
PBS is only down for a few minutes, in step 5):

1. Pick a time without backups and stop the timers:
   `systemctl stop upb-backup.timer upb-offsite.timer`. In the PBS web UI,
   Datastore > `unraid` > Options > Maintenance mode: **Read only**.
2. Proxmox VE: VM > Hardware > Add > Hard Disk, the new size, same storage,
   Discard, IO thread, SSD emulation; under Advanced untick *Backup* and tick
   *Skip replication*.
3. PBS web UI: Administration > Storage / Disks > Directory > Create: the new
   disk (`lsblk` shows which one), ext4, name `unraid2`, **untick** *Add as
   Datastore*. It's mounted at `/mnt/datastore/unraid2`.
4. Copy, then check nothing differs (the second command prints nothing):
   ```sh
   rsync -aHAX --numeric-ids --info=progress2 /mnt/datastore/unraid/ /mnt/datastore/unraid2/
   rsync -aHAX --numeric-ids --dry-run --itemize-changes /mnt/datastore/unraid/ /mnt/datastore/unraid2/
   ```
5. Mount the new disk at `/mnt/datastore/unraid` instead of the old one:
   ```sh
   cp /etc/systemd/system/mnt-datastore-unraid.mount /root/mnt-datastore-unraid.mount.old
   NEW=$(findmnt -no UUID /mnt/datastore/unraid2); echo "$NEW"
   systemctl stop proxmox-backup-proxy proxmox-backup
   systemctl disable --now mnt-datastore-unraid2.mount
   rm /etc/systemd/system/mnt-datastore-unraid2.mount
   systemctl stop mnt-datastore-unraid.mount
   sed -i "s#^What=.*#What=/dev/disk/by-uuid/$NEW#" /etc/systemd/system/mnt-datastore-unraid.mount
   systemctl daemon-reload
   systemctl start mnt-datastore-unraid.mount
   df -h /mnt/datastore/unraid        # the new size
   systemctl start proxmox-backup proxmox-backup-proxy
   ```
6. Maintenance mode back to none, then Datastore > `unraid` > Content >
   **Verify All**, `upb check` and `upb backup sftpgo`. Start the timers
   again: `systemctl start upb-backup.timer upb-offsite.timer`.
7. Only when the verify is OK: Proxmox VE > VM > Hardware > the old disk >
   Detach, then select *Unused Disk* > Remove.

To undo step 5 before step 7: copy `/root/mnt-datastore-unraid.mount.old`
back to `/etc/systemd/system/mnt-datastore-unraid.mount`, then `systemctl
daemon-reload` and restart the mount and the two PBS services.

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
enabling them. To update later, see [Updating](#updating).

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

## Offsite copy

`upb offsite` copies the same shares, encrypted, to Google Drive, and can take
the datastore of the PBS on Unraid (your Proxmox VM backups) along:
[offsite.md](offsite.md).

## Updating

1. On your PC, download `main` as a ZIP from GitHub (logged in, since the
   repository is private):
   <https://github.com/nkskater/unraid-to-proxmox-backups/archive/refs/heads/main.zip>
2. Copy it to the VM: `scp unraid-to-proxmox-backups-main.zip root@192.168.1.20:`
3. On the VM, check no backup is running (`systemctl is-active upb-backup
   upb-offsite` prints `inactive` twice), then:
   ```sh
   cd ~
   rm -rf unraid-to-proxmox-backups-main
   unzip -q unraid-to-proxmox-backups-main.zip
   cd unraid-to-proxmox-backups-main
   bash install.sh
   upb version && upb check
   ```

The update replaces `/opt/upb` and the systemd unit files. It never changes
`/etc/upb/upb.conf`, existing job files or `/etc/upb/secrets/`; enabled
timers stay enabled, and `pbs-setup.sh` doesn't need to run again. New job
templates are added to `jobs.d/` (check `JOB_ENABLED` in them). To see
settings a release added: `diff /etc/upb/upb.conf config/upb.conf.example`.
Don't delete a job file to turn a job off: an update brings it back. Set
`JOB_ENABLED=false` instead.
