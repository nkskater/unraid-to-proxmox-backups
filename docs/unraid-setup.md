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
| Skip? (per container) | **Yes** for containers whose data you don't need, e.g. `ComfyUI-Nvidia-Docker` (138 GB of image models), and for the ones the plugin log reports as "does not have any volume to back up" | Keeps each run small on the array and in PBS, and stops containers without data from being restarted for nothing |
| (optional) model list | `docker exec ollama ollama list > /mnt/user/appdata/ollama/models-list.txt`, e.g. as a User Script | The list is backed up even though the models aren't, so you know what to `ollama pull` after a restore |
| Excluded folders (click a container's name, or use the Global exclusion list) | large folders you can download again inside containers you do keep, e.g. `/mnt/user/appdata/ollama/models` for Ollama | Downloaded models and caches can be hundreds of GB; they can be downloaded again after a restore (`ollama pull`) |

Uncompressed runs are bigger on the array than compressed ones. Lowering the
local retention more than makes up for it. Old compressed runs you no longer
want can simply be deleted from the share; PBS never needed them.

To see what's big before choosing exclusions: the largest archives in the
newest run (named after the containers), and the largest appdata folders:

```sh
cd "/mnt/user/Backup/appdata backup" && ls -lhS "$(ls -t | head -1)" | head -15
du -sh /mnt/user/appdata/* | sort -h | tail -15
```

### Plex, Jellyfin and other big containers

Most of a media server's appdata is caches and generated images. Exclude
these per container (click its name and tick the folders) or in the Global
exclusion list (one path per line; P = `/mnt/user/appdata/Plex-Media-Server/Library/Application Support/Plex Media Server`):

| Exclude | Why it's safe |
|---|---|
| `P/Cache`, `P/Codecs`, `P/Crash Reports`, `P/Diagnostics`, `P/Drivers`, `P/Logs`, `P/Updates` | Rebuilt or re-downloaded by Plex on its own |
| `P/Media` | Video preview thumbnails and chapter images; regenerated after a restore (takes hours of CPU) |
| `P/Plug-in Support/Caches` | Plug-in caches, rebuilt automatically |
| `P/Metadata` (optional) | Posters and artwork; re-downloaded, but slowly, and custom posters are lost |
| `/mnt/user/appdata/Jellyfin/cache` | Jellyfin's cache (the container's `/cache` mapping) |
| `/mnt/user/appdata/Jellyfin/metadata` (optional) | Downloaded posters, backdrops and people images. After a restore, run a library refresh with "Replace all images"; custom images are lost |
| `MediaCover` in the *arr apps' appdata (lidarr, radarr, sonarr, …) | Posters the apps download again |
| `cache` in Open WebUI's appdata (`ollama-webui` here) | Downloaded embedding and speech models; keep `webui.db` and `uploads` |

Never exclude Plex's `Plug-in Support/Databases` folder or `Preferences.xml`,
or Jellyfin's `data`, `config` and `root` (library definitions) folders: they hold the library databases
(users, watch history, collections, settings) and the servers' identity. To see what each Plex folder takes:

```sh
du -sh "/mnt/user/appdata/Plex-Media-Server/Library/Application Support/Plex Media Server"/* | sort -h
```

### Removed containers

The plugin only backs up the folders of containers that exist. Removing a
container in Unraid keeps its appdata folder (reinstalling it from Apps >
Previous Apps picks the folder up again), so folders of removed containers
are not in the runs. Check that no container uses a folder before deleting
it:

```sh
docker ps -aq | xargs docker inspect -f '{{.Name}}: {{range .Mounts}}{{.Source}} {{end}}' \
  | grep -E 'appdata/ollama(/| |$)'
```

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

NFS access is by IP only; the username/password settings you may have on a
share are for SMB and aren't affected. *Security: Secure* is not enough
here: it exports read-only to every host and maps the PBS VM's root user to
`nobody`, so files `nobody` can't read would fail to back up.

If another machine already mounts a share over NFS, keep it in the Private
rule (entries are separated by spaces), e.g.
`192.168.1.20(ro,sec=sys,no_root_squash) 192.168.1.10(ro,sec=sys)`. To see
who is connected: `ss -tn state established '( sport = :2049 )'` on Unraid,
and `grep -A4 '^nfs' /etc/pve/storage.cfg` on a Proxmox node.

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
