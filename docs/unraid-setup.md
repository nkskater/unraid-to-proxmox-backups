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
| Destination | `/mnt/user/Backup/appdata backup` (as now) | The `EXPORT` of the `appdata-backup` job on the PBS VM |
| Flash drive backup | **on**, to `/mnt/user/Backup/flash drive backup` (as now) | The `flash-backup` job. Unraid config, disk assignments, Docker templates and license |
| Keep / delete old backups | keep **1–2** runs | PBS keeps the history and only reads the newest run. Every extra local copy is array space: the old compressed copies currently fill about 870 GB of `appdata backup` and 53 GB of `flash drive backup`. |
| Schedule | as you like, finishing before 06:00 | The PBS VM pulls every night at 06:00 and waits if the plugin is still writing. On nights without a new plugin run, nothing changed, so the pull is quick and costs no space. PBS's appdata restore points are only as fresh as the plugin's last run. |
| Containers | stopped during their backup (the default) | Gives consistent copies of databases (Postgres, SQLite) |
| Per-container excluded folders | large data you can download again, e.g. Ollama's `models` folder (`/mnt/user/appdata/ollama/models`) | Downloaded LLMs can be hundreds of GB. Excluding them keeps each run small on the array and in PBS; after a restore, `ollama pull` fetches them again |

Uncompressed runs are bigger on the array than compressed ones. Lowering the
local retention more than makes up for it. Old compressed runs you no longer
want can simply be deleted from the share; PBS never needed them.

To see what's big before choosing exclusions:
`du -sh /mnt/user/appdata/* | sort -h | tail -15`.

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

| Share | For jobs |
|---|---|
| `Backup` | `appdata-backup`, `flash-backup` (its subfolders are mounted) |
| `photos_immich` | `photos-immich` |
| `paperless` | `paperless` |
| `Everything Else` | `everything-else` |
| `sftpgo` | `sftpgo` |
| `syncthing backup` | `syncthing-backup` |

Don't export the media shares (huge, and they can be downloaded again),
`system` (the Docker image and libvirt image; containers are rebuilt from
the templates in the flash backup), or `pbs_data` / `proxmox`.

Only the two Appdata Backup folders inside `Backup` are backed up; its
other folders (`configs`, `zorinos`) are left out.

To check from the PBS VM: `showmount -e 192.168.1.180` lists what Unraid
exports and to whom. `upb check` mounts every enabled job's export.

## Security note

NFS with `sec=sys` trusts the client's IP address. Anyone on your LAN who
can take over the PBS VM's IP could read the exported shares, read-only.
That is the usual trade-off for NFS on a home network. Keep the export list
to the shares that need backing up.
