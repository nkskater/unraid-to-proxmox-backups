# Restoring

## Before you need it

Keep these **off the Unraid server**:

- the encryption key, or its paper copy from `upb init-key`
- the PBS root password (or another admin login)
- this repository, or at least this page

Then do a test restore now and then. It's the only way to know the backups
work.

## Finding a snapshot

```sh
upb snapshots            # everything
upb snapshots appdata    # one job: host/unraid-appdata/2026-09-25T03:00:12Z ...
```

Restore commands use the **latest** snapshot unless you pass one of these
paths.

## Restoring a whole archive

Archive names are the names in the job's `SOURCES` (plus `dumps` for database
dumps). Restore into a **new, empty** directory, then copy what you need:

```sh
upb restore appdata appdata /mnt/user/restore/appdata
upb restore databases dumps /mnt/user/restore/dumps
upb restore flash flash /mnt/user/restore/flash host/unraid-flash/2026-09-20T03:00:05Z
```

If the client says the archive doesn't exist, run
`upb client snapshot files <snapshot>` to see the exact names. Snapshots
taken with `metadata` or `data` change detection store each archive as a
`name.mpxar` + `name.ppxar` pair, and you may need to pass `name.mpxar`.

## Restoring single files

```sh
upb shell appdata appdata
```

This opens an interactive shell inside the backup:

```
pxar:/ > cd homeassistant
pxar:/homeassistant/ > ls
pxar:/homeassistant/ > select configuration.yaml
pxar:/homeassistant/ > restore-selected /mnt/user/restore/ha
pxar:/homeassistant/ > exit
```

`find <pattern> --select` selects matches anywhere, and `help` lists all
commands. With encryption off (`PBS_ENCRYPTION=false`), you can also browse
and download files in the PBS web UI (Datastore > Content > select the
snapshot > File Browser).

## App recipes

**One container's appdata**: stop the container, restore
`appdata` into a scratch folder, replace
`/mnt/user/appdata/<container>` with the restored copy (keep the old one
until it works), then start the container.

**A Postgres database** (from the `databases` job's `dumps` archive):

```sh
upb restore databases dumps /mnt/user/restore/dumps
# stop the apps that use it first; the dump includes DROP statements (--clean)
gunzip -c /mnt/user/restore/dumps/postgres-postgresql17.sql.gz \
  | docker exec -i postgresql17 psql -U postgres -d postgres
```

For **Immich**, follow Immich's restore guide
(<https://immich.app/docs/administration/backup-and-restore>). The
`postgres-PostgreSQL_Immich.sql.gz` dump is the same `pg_dumpall` file it
expects. Restore the database first, then the `photos` archive to the path
mapped to `/photos`.

**Paperless-ngx**: restore the `export` archive into the folder mapped to
`/usr/src/paperless/export` of a fresh Paperless instance, then:

```sh
docker exec -it paperless-ngx document_importer ../export
```

**Flash drive / whole server**: create a new USB with the Unraid USB
Creator, restore the `flash` archive, and copy its `config/` folder onto the
new stick (replacing the fresh one). Boot, then transfer the license to the
new USB GUID (Tools > Registration). Your disk assignments, shares, Docker
templates and plugins come back with it. Then reinstall upb, restore
`secrets/` from your offline copies, and restore appdata before starting
containers.

## Restoring without Unraid

Any Linux machine with `proxmox-backup-client` works, including the PBS host
itself:

```sh
export PBS_REPOSITORY='root@pam@<pbs-host>:unraid'
proxmox-backup-client snapshot list
proxmox-backup-client restore host/unraid-flash flash.pxar ./flash \
  --keyfile ./encryption.key
```

If the key file itself is gone, the paper key printed by `upb init-key`
holds the same key data (as text and a QR code). See "Paperkey" in the
Proxmox Backup client documentation for turning it back into a key file.
