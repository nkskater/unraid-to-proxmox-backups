# Proxmox node configuration backup

Your VM backups don't include the Proxmox nodes' own settings. `upb
host-backup` runs on each Proxmox VE node every night and backs them up to
the **PBS on Unraid** (the one with the `pbs_data` datastore), in a separate
namespace `pve-hosts`. From there the [pbs-data offsite job](offsite.md#proxmox-vm-backups-pbs-data)
takes them to Google Drive along with the VM backups.

Why the PBS on Unraid: the backup has to live off the node it describes. The
`pbs-unraid` VM runs on a Proxmox node, so it's the wrong place.

What each snapshot (`host/pve-<hostname>`) contains:

| Archive | What's in it |
|---|---|
| `etc` | All of `/etc`: network (`network/interfaces`), `hosts`, iSCSI (`iscsi/`), `fstab`, boot and passthrough settings (`default/grub`, `kernel/cmdline`, `modprobe.d`, `modules`), SSH keys, apt sources, `cron.d`. **Including `/etc/pve`**: VM and container configs, `storage.cfg`, users, firewall, backup jobs, `corosync.conf`, keys in `priv/` |
| `root` | `/root`: scripts, `.ssh/authorized_keys` |
| `usr-local` | `/usr/local`: anything you installed by hand |
| `var-spool-cron` | Your crontabs |
| `pve-cluster-db` | A consistent copy of the cluster database (`/var/lib/pve-cluster/config.db`), taken while the cluster keeps running |

Each run takes seconds; PBS deduplicates, so a year of nightly snapshots
takes almost no space.

## 1. Prepare the PBS on Unraid (once)

Everything in this step runs on the **PBS VM on Unraid**, as root.

1. Note its IP address and its datastore name (web UI → Datastore, in the
   left menu).
2. Copy the repository ZIP there, as for the other VM
   ([pbs-setup.md](pbs-setup.md#2-install-upb)), and unzip it. You don't run
   `install.sh` on this PBS.
3. Create the namespace, a backup-only user and token, and a retention job
   for that namespace (replace `<datastore>`):
   ```sh
   cd unraid-to-proxmox-backups-main
   DATASTORE=<datastore> NAMESPACE=pve-hosts PBS_USER=pve-host@pbs TOKEN_NAME=hosts \
     TOKEN_FILE=/root/pve-host-token GC_SCHEDULE= VERIFY_SCHEDULE= \
     bash proxmox/pbs-setup.sh
   ```
   - To create the namespace it asks once for that PBS's `root@pam` password,
     and may ask you to confirm the server's fingerprint (answer `y`).
   - The token can only add backups, and only in `pve-hosts`.
   - Retention (08:00: keep 3 last, 14 daily, 8 weekly, 12 monthly, 3 yearly)
     applies to the namespace only. `GC_SCHEDULE=` and `VERIFY_SCHEDULE=`
     leave that PBS's own garbage collection and verify jobs alone.
   - At the end it prints `PBS_AUTH_ID` and `PBS_FINGERPRINT`. The token
     secret is in `/root/pve-host-token`.

## 2. Install on each Proxmox node

On each node (192.168.1.10 and 192.168.1.11):

```sh
# on your PC
scp unraid-to-proxmox-backups-main.zip root@192.168.1.10:
# on the node, as root
unzip -q unraid-to-proxmox-backups-main.zip && cd unraid-to-proxmox-backups-main
bash install.sh --pve-host
```

This installs upb to `/opt/upb` (plus `sqlite3` if it's missing), creates
`/etc/upb/host-backup.conf`, and installs the `upb-host-backup` service and
timer. Nothing else on the node changes.

Copy the token secret from the PBS on Unraid:

```sh
scp root@<unraid-pbs-ip>:/root/pve-host-token /etc/upb/secrets/pve-host-token
chmod 600 /etc/upb/secrets/pve-host-token
```

Edit `/etc/upb/host-backup.conf`:

```bash
PBS_SERVER="<unraid-pbs-ip>"
PBS_DATASTORE="<datastore>"
PBS_FINGERPRINT="<printed by pbs-setup.sh>"
```

## 3. Test and schedule

```sh
upb host-backup --dry-run      # the exact client command
upb host-backup
upb host-client snapshot list  # host/pve-proxmox/...
systemctl enable --now upb-host-backup.timer
```

It runs daily at 05:30. In the web UI of the PBS on Unraid you'll find it
under Datastore → Content, namespace `pve-hosts`.

Notifications work as for upb (`NOTIFY_EMAIL`, `NOTIFY_NTFY_URL`,
`HEALTHCHECK_URL` in `host-backup.conf`); use one healthchecks.io check per
node.

The backup contains secrets (`/etc/pve/priv`, SSH host keys). It stays on
your PBS and is encrypted on Google Drive. To encrypt it on the PBS as well,
see the Encryption section in `host-backup.conf`.

## Restoring

### Get a file back

```sh
upb host-restore /root/host-restore     # the latest snapshot, one folder per archive
ls /root/host-restore                   # etc  pve-cluster-db  root  usr-local  var-spool-cron
```

`upb host-client snapshot list` shows older snapshots; pass one as the second
argument. `host-restore` changes nothing on the node: copy back what you
need. The PBS web UI's File Browser works too (namespace `pve-hosts`).

### One node died, the other still runs

The cluster keeps everything in `/etc/pve` (VM configs, storage, users,
backup jobs) on the surviving node, so you only need the dead node's own
settings. Follow the Proxmox guide for removing and re-adding a node
(<https://pve.proxmox.com/pve-docs/chapter-pvecm.html#_remove_a_cluster_node>);
in short:

1. On the surviving node: `pvecm qdevice remove` (your tie-breaker
   `corosync-qnetd` on Unraid has to be removed before nodes change), then
   `pvecm delnode <dead-node-name>`.
2. Reinstall Proxmox VE on the dead node with its old hostname and IP.
3. Install upb with `--pve-host`, put back the token and `host-backup.conf`
   settings, then `upb host-restore /root/host-restore`.
4. Copy back the node's own settings from `/root/host-restore/etc/`,
   comparing with the fresh files first:
   - `network/interfaces` (check the network card names with `ip link`) and `hosts`
   - `iscsi/` and any `multipath` files, for the `iscsi2` storage
   - `default/grub`, `kernel/cmdline`, `modprobe.d/`, `modules` for passthrough;
     then `update-initramfs -u -k all` and `proxmox-boot-tool refresh`
     (or `update-grub`)
   - extra disk lines in `fstab`
   - `/root/host-restore/root/.ssh/authorized_keys`, your scripts, and your
     crontab: `crontab /root/host-restore/var-spool-cron/crontabs/root`
5. Reboot, then join the cluster again from this node:
   `pvecm add <surviving-node-ip>`. It gets `/etc/pve` from the cluster. Don't
   copy `/etc/pve` or the cluster database onto a node that joins a running
   cluster.
6. Add the tie-breaker back: install `corosync-qdevice` on both nodes
   (`apt install corosync-qdevice`), then on one of them run
   `pvecm qdevice setup 192.168.1.180`.

### Both nodes are gone

Then `/etc/pve` has to come from the backup. Rebuilding is the safe route:

1. Reinstall both nodes, restore each node's own settings as above, and
   create a new cluster (`pvecm create` on one, `pvecm add` on the other).
2. Copy the cluster-wide settings from one node's backup into the new
   `/etc/pve`: `storage.cfg`, `datacenter.cfg`, `user.cfg`, `jobs.cfg`
   (backup jobs), `firewall/`, and the storage passwords in `priv/storage/`.
3. Virtual machines:
   - Disks that survived on shared storage (e.g. iSCSI): copy the configs from
     `etc/pve/nodes/<old-node>/qemu-server/` and `lxc/` back into
     `/etc/pve/nodes/<node>/`, and the VMs are back.
   - Otherwise restore them from the PBS on Unraid (or from Google Drive, see
     [offsite.md](offsite.md#the-whole-pbs_data-datastore)).

The full cluster database copy (`pve-cluster-db/config.db`) is there for
experts; see "Recovery" in the Proxmox cluster filesystem docs
(<https://pve.proxmox.com/pve-docs/chapter-pmxcfs.html>).
