# Proxmox side: Proxmox Backup Server

The backups go to a **Proxmox Backup Server (PBS)**, not to Proxmox VE
itself. PBS is Proxmox's free backup product: deduplicated, verified
storage with its own retention schedules. The same PBS can also back up your
Proxmox VMs and containers.

## 1. Pick where PBS runs

| Option | Good | Watch out for |
|---|---|---|
| **Install on a PVE node** (`apt install proxmox-backup-server`) | Simplest, no extra VM, officially supported | Datastore disks are tied to that node |
| **VM on the cluster** | Isolated, easy to move | Give the datastore its own disk. If the cluster is gone, attach that disk to a fresh PBS to get the backups back |
| **Separate machine** | Survives a cluster failure | Another box to run |

Whichever you choose, the datastore should live on **disks that hold nothing
else**. A dedicated disk or a ZFS dataset on its own pool is ideal. Size it
at roughly 1.5–2× the data you back up. Dedup keeps history cheap, but
photos don't compress.

Install guide: <https://pbs.proxmox.com/docs/installation.html>

## 2. Create the datastore, token and schedules

Copy `proxmox/pbs-setup.sh` to the PBS host and run it as root:

```sh
scp proxmox/pbs-setup.sh root@<pbs-host>:
ssh root@<pbs-host>

# creates the datastore if it doesn't exist yet
DATASTORE_PATH=/mnt/datastore/unraid ./pbs-setup.sh
```

It creates:

| Object | Default | Why |
|---|---|---|
| Datastore | `unraid` | Keeps Unraid data apart from VM backups |
| User | `unraid-backup@pbs` | Owner of the backups |
| API token | `unraid-backup@pbs!unraid` | What Unraid logs in with. **The secret is shown once; copy it** |
| ACL | `DatastoreBackup` on `/datastore/unraid` | Can add backups, **can't delete or prune** them |
| Prune job | daily 06:00: keep 3 last, 14 daily, 8 weekly, 12 monthly, 3 yearly | Retention, run by PBS |
| Garbage collection | daily 07:00 | Frees chunks that pruned snapshots no longer use |
| Verify job | Saturday 08:00, re-verify after 30 days | Detects bit rot and disk problems |

Everything can be changed with environment variables, e.g.
`KEEP_DAILY=30 NAMESPACE=unraid DATASTORE=main ./pbs-setup.sh`. See the top
of the script. Re-running it is safe: it updates schedules and retention
and leaves existing objects alone.

At the end it prints the values for `upb.conf`:

```
PBS_SERVER="192.168.1.20"
PBS_DATASTORE="unraid"
PBS_AUTH_ID="unraid-backup@pbs!unraid"
PBS_FINGERPRINT="64:d3:…"
```

## 3. Network

Unraid must reach PBS on **TCP 8007**. If the Proxmox firewall is on, allow
8007 from the Unraid server (`192.168.1.180`).

## Optional: VM backups to the same PBS

In Proxmox VE: Datacenter > Storage > Add > Proxmox Backup Server. Use a
different datastore (or a namespace) and a separate token, so VM backups and
Unraid backups have their own permissions and retention.

## Optional: offsite copy

PBS can **pull** a datastore from another PBS (sync jobs). That's the easy
way to get a copy off site, e.g. a small PBS at a friend's house. PBS 4 can
also use S3-compatible storage as a datastore backend. Because the Unraid
backups are encrypted on the client, an offsite copy never sees plaintext.
