# Restoring

Everything below runs on the **PBS VM** unless it says otherwise. The NFS
exports are read-only on purpose, so restored data travels back to Unraid
over SSH (`rsync`) or through your PC (web UI download, then copy into a
share).

## Finding a snapshot

```sh
upb snapshots                  # everything
upb snapshots appdata-backup   # host/unraid-appdata-backup/2026-09-25T05:00:12Z ...
```

Commands use the **latest** snapshot unless you pass one of these paths as
the last argument.

## Browsing

The easiest way, with encryption off (the default): PBS web UI >
Datastore `unraid` > Content > pick a snapshot > **File Browser**. From
there you can download single files, or whole folders as an archive.

On the command line:

```sh
upb shell photos                 # interactive: cd, ls, find, select, restore-selected
upb mount photos /mnt/restore    # whole backup as a read-only folder
umount /mnt/restore
```

## Getting data back onto Unraid

Mount the backup on the PBS VM and `rsync` it to Unraid. Nothing needs to
fit on the PBS VM's own disk:

```sh
upb mount photos /mnt/restore
rsync -a --info=progress2 /mnt/restore/library/ \
  root@192.168.1.180:/mnt/user/photos-restore/library/
umount /mnt/restore
```

Restore into a new folder, check it, then swap it in. Use
`upb restore JOB DIR` to write a full copy to a local folder on the VM
instead.

## Recipes

**Appdata (one container or all)**: the plugin's archives are inside the
`appdata-backup` snapshots, one dated folder per plugin run.

1. `upb mount appdata-backup /mnt/restore` and `ls /mnt/restore` to find the
   run you want.
2. Copy that dated folder back into the plugin's destination on Unraid:
   ```sh
   rsync -a /mnt/restore/<dated-folder> root@192.168.1.180:/mnt/user/backups/appdata/
   ```
3. On Unraid: Settings > Appdata Backup > Restore, pick that backup and the
   containers to restore. The plugin stops and starts them for you.

**Immich**: restore the database first, then the library.

- Database: Immich's own dumps are in the library's `backups/` folder, and
  the Appdata Backup archive of `PostgreSQL_Immich` holds its data folder.
  Follow Immich's guide:
  <https://immich.app/docs/administration/backup-and-restore>.
- Library: `upb mount photos …` and `rsync` it back as shown above.
  Thumbnails and transcoded videos weren't backed up; Immich regenerates
  them (Administration > Jobs).

**Flash drive / whole server**: the flash backup is in the
`appdata-backup` snapshots with the plugin's other output.

1. Download it through the web UI's File Browser.
2. Make a new USB stick with the Unraid USB Creator.
3. Copy the backup's `config/` folder onto the stick, replacing the fresh
   one.
4. Boot, and move the license to the new stick (Tools > Registration).

Disk assignments, shares, Docker templates and plugins come back with it.
Then restore appdata as above before starting containers.

## If the PBS VM itself is gone

The backups live on the datastore disk. Install a fresh PBS (as a VM or on
any machine), attach the disk, and add the existing datastore (Datastore >
Add Datastore, with the same path and "reuse existing datastore"). The
snapshots are all there. Then install upb again from this repo.

## If you turned encryption on

Restores need the key file (`/etc/upb/secrets/encryption.key`), and the web
UI can't browse encrypted snapshots. If the key file is lost, the paper key
printed by `upb init-key` holds the same key data. See "Paperkey" in the
Proxmox Backup client docs for turning it back into a key file.
