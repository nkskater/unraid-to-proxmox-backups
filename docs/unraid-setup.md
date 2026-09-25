# Unraid side

Nothing gets installed on Unraid. You configure two things:

1. the **Appdata Backup** plugin, which makes consistent copies of appdata
   and the flash drive into a share, and
2. **read-only NFS exports** of that share (and any others you want backed
   up) to the PBS VM.

## 1. Appdata Backup plugin

Settings > Appdata Backup:

| Setting | Use | Why |
|---|---|---|
| **Compression** | **No** | Compressed archives change completely every night, so PBS can't deduplicate them and stores every night in full. Uncompressed tars deduplicate well, and PBS compresses chunks itself. |
| Destination | a folder in a share, e.g. `/mnt/user/backups/appdata` | This is the `EXPORT` of the `appdata-backup` job on the PBS VM |
| Flash drive backup | **on** | Unraid config, disk assignments, Docker templates and license go along |
| Keep / delete old backups | a few days (2–3 is plenty) | PBS keeps the long history; the local copies are for quick restores |
| Schedule | e.g. daily 03:00 | Finishes before the PBS VM pulls at 05:00 |
| Containers | stopped during their backup (the default) | Gives consistent copies of databases (Postgres, SQLite) |

After switching compression off, the next few runs take more disk space on
the share (uncompressed tars next to the old compressed ones) until the old
ones age out.

The plugin backs up the `PostgreSQL_Immich` and `postgresql17` data folders
with those containers stopped, so they restore cleanly. A copy of a
database's data folder only restores into the **same major Postgres
version**; Immich's own dumps (below) don't have that limit.

## 2. NFS exports

1. Settings > NFS: **Enable NFS: Yes**.
2. For each share the PBS VM should read (Shares > *share* > NFS Security
   Settings):
   - **Export:** Yes
   - **Security:** Private
   - **Rule:** `<PBS VM IP>(ro,sec=sys,no_root_squash)`, e.g.
     `192.168.1.20(ro,sec=sys,no_root_squash)`

   - `ro`: the PBS VM can never change anything on Unraid.
   - `no_root_squash`: lets it read files that aren't world-readable (the
     plugin's archives, appdata owned by other users).
   - The IP limits the export to the PBS VM alone. Give that VM a fixed IP
     (DHCP reservation or static).

Shares to export:

| Share | For job | Notes |
|---|---|---|
| the one holding the Appdata Backup destination (e.g. `backups`) | `appdata-backup` | required |
| the Immich library (host path of `/photos`, e.g. `photos`) | `photos` | Immich also writes nightly database dumps into `backups/` there |
| documents, Syncthing folders, … | one job each | optional |

Leave the media shares out: they're huge and can be downloaded again.

To check from the PBS VM: `showmount -e 192.168.1.180` lists what Unraid
exports and to whom. `upb check` mounts every enabled job's export.

## Security note

NFS with `sec=sys` trusts the client's IP address. Anyone on your LAN who
can take over the PBS VM's IP could read the exported shares, read-only.
That is the usual trade-off for NFS on a home network. Keep the export list
to the shares that need backing up.
