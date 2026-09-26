# Restoring

Everything below runs on the **PBS VM** unless it says otherwise. The NFS
exports are read-only on purpose, so restored data travels back to Unraid
over SSH (`rsync`) or through your PC (web UI download, then copy into a
share).

## Finding a snapshot

```sh
upb snapshots                  # everything
upb snapshots appdata-backup   # host/unraid-appdata-backup/2026-09-25T06:00:12Z ...
```

Commands use the **latest** snapshot unless you pass one of these paths as
the last argument.

## Browsing

The easiest way, with encryption off (the default): PBS web UI >
Datastore `unraid` > Content > expand the group and the snapshot, then click
the **folder icon** in the `<job>.mpxar.didx` row (not the download arrow:
that downloads PBS's raw archive format). In the File Browser, select a file
or folder and click **Download**; folders come as a `.zip`.

On the command line:

```sh
upb shell photos-immich                 # interactive: cd, ls, find, select, restore-selected
upb mount photos-immich /mnt/restore    # whole backup as a read-only folder
umount /mnt/restore
```

## Getting data back onto Unraid

Mount the backup on the PBS VM and `rsync` it to Unraid. Nothing needs to
fit on the PBS VM's own disk:

```sh
upb mount photos-immich /mnt/restore
rsync -a --info=progress2 /mnt/restore/library/ \
  root@192.168.1.180:/mnt/user/photos_immich-restore/library/
umount /mnt/restore
```

Restore into a new folder, check it, then swap it in. Use
`upb restore JOB DIR` to write a full copy to a local folder on the VM
instead.

If `rsync` is missing on the VM: `apt install -y rsync`. For a remote path
with spaces, quote the whole destination and don't add backslashes: rsync
3.2.4 and newer (as on PBS 4) escapes remote paths itself, so a backslash
would end up in the folder name.

## Recipes

**Appdata (one container or all)**: the plugin's archives are inside the
`appdata-backup` snapshots, one dated folder per plugin run.

1. `upb mount appdata-backup /mnt/restore` and `ls /mnt/restore` to find the
   run you want.
2. Copy that dated folder back into the plugin's destination on Unraid:
   ```sh
   rsync -a /mnt/restore/<dated-folder> "root@192.168.1.180:/mnt/user/Backup/appdata backup/"
   ```
3. On Unraid: Settings > Appdata Backup > Restore, pick that backup and the
   containers to restore. The plugin stops and starts them for you.

**Immich**: restore the database first, then the library.

- Database: Immich's own dumps are in the library's `backups/` folder, and
  the Appdata Backup archive of `PostgreSQL_Immich` holds its data folder.
  Follow Immich's guide:
  <https://immich.app/docs/administration/backup-and-restore>.
- Library: `upb mount photos-immich …` and `rsync` it back as shown above.
  Thumbnails and transcoded videos weren't backed up; Immich regenerates
  them (Administration > Jobs).

**Flash drive / whole server**: the flash backups are in the
`flash-backup` snapshots.

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
