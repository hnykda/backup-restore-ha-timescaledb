# backup-restore-ha-timescaledb

A repository with tools and examples to backup, validate and restore postgresql+timescaledb with LTSS for HA (referenced [here](https://community.home-assistant.io/t/home-assistant-add-on-postgresql-timescaledb/198176/205?u=kotrfa)). This is definitely not intended as a "use as is" - you have to change the commands based on your needs. Still, I find it valuable to have one working example of how this works.

# The goal

Being able to dump data from the `timescaledb` postgres version and restoring them in a local DB version.

# Steps

## Preparing the env

0. have `docker` and `pg_restore` installed
1. clonse this repository and go inside it
2. prepare the command to start the local version of the DB that the addon uses:

```
docker run \
  --entrypoint "/bin/bash" \
  -p 5432:5432 \
  -e POSTGRES_PASSWORD=strong-password \
  -v $(pwd)/data:/data:rw \
  -v $(pwd)/init.sh:/scripts/init.sh \
  # HERE you need to adjust the image architectore and version depending on your machine and addon version
  husselhans/hassos-addon-timescaledb-aarch64:3.0.2 \
  /scripts/init.sh
```

alternatively, you can use the `docker-compose.yaml`

## Creating a backup

1. `ssh` to the local HA instance, e.g. `ssh root@192.168.0.202`
2. use `pg_dump` to dump the data (you will be prompted for the homeassistant's DB password of postgres user):

    ```
   apk update
   apk add postgresql

   # adjust the name of the database after the -d switch - this is in the addon's settings
   pg_dump -h 77b2833f-timescaledb -U postgres -Fc -Z 9 -d homeassistant --no-owner --no-privileges --clean -f ha.dump
   ```

3. copy the dump from HA instance to your localhost, e.g.: `scp root@192.168.0.202:/root/ha.dump .`

## Restoring

1. spin up a new container for our DB that we want to restore the data to by running the docker command from the above. This will expose `postgres` on `localhost:5432` with the `strong-password` password for the `postgres` user.
2. Run the pg restore command:
    
    ```
    # you will be prompted for password, by default 'strong-password'
    pg_restore -U postgres -h localhost -Fc -d postgres --no-owner --no-privileges --create --clean ha.dump
    ```

## Validating the dump went fine

1.  validate that you are able to get some older data from the DB. E.g. sshing to the local HA instance and running the following command returns a record that is 6 months old, showing that there are historical data and not just the recorder recent ones (by default 10 days):

    ```
    $ psql -h 77b2833f-timescaledb -U postgres -d homeassistant -c "SELECT entity_id AS metric, state, time FROM ltss WHERE entity_id = 'update.home_assistant_core_update' AND state = 'on' ORDER BY 3 LIMIT 1"

                  metric               | state |             time
    -----------------------------------+-------+-------------------------------
     update.home_assistant_core_update | on | 2023-07-25 10:35:51.436003+00
    (1 row)
    ```

2.  Now execute the same command against the local restored version, and see if it's the same:

    ```
    $ psql -h localhost -U postgres -d homeassistant -c "SELECT entity_id AS metric, state, time FROM ltss WHERE entity_id = 'update.home_assistant_core_update' AND state = 'on' ORDER BY 3 LIMIT 1"

                  metric               | state |             time
    -----------------------------------+-------+-------------------------------
     update.home_assistant_core_update | on | 2023-07-25 10:35:51.436003+00
    (1 row)
    ```

3.  If it is, you won!

# FAQ and tips

1. if the import fails, stop the containers, wipe the local `data` directory and start over
2. `pgadmin` container in the `docker-compose.yaml` is optional, you can ignore it, it's there for analysis if you need to
3. for some reason, the restore reports some errors such as `pg_restore: error: could not execute query: ERROR:  operation not supported on chunk tables`, and reported couple of errors. I believe it's OK. However, it would be probably cleaner to follow the official [TimescaleDB guide](https://docs.timescale.com/migrate/latest/pg-dump-and-restore/pg-dump-restore-from-timescaledb/), with something like this (I haven't tested this):

    ```
    # dumping data from the HA TimescaleDB instance

    pg_dump -d "homeassistant" \
        -h localhost -p 5433 -U postgres \
        --format=plain \
        --quote-all-identifiers \
        --no-tablespaces \
        --no-owner \
        --no-privileges \
        --file=dump-tsc.sql

    psql -U postgres -d postgres -h localhost -c 'CREATE DATABASE harestore;'

    # then restoring with something like this

    psql -v ON_ERROR_STOP=1 -d "harestore" \
        -h localhost -U postgres --echo-errors \
        -c "SELECT public.timescaledb_pre_restore();" \
        -f dump-tsc.sql \
        -c "SELECT public.timescaledb_post_restore();"

    # but here I got some errors...
    ```

# Cronjob backuping the DB

This is what I use to backup the DB from HA

    ```
    #!/bin/bash
    set -e

    BACKUP_DIR=/root/db-backup # on remote
    ADDRESS=root@ssh_ha  # this is in .ssh/config
    BACKUP_NAME=$(date -Iseconds).dump
    BACKUP_FILE=$BACKUP_DIR/$BACKUP_NAME

    echo "STARTING" && \
        ssh $ADDRESS mkdir -p $BACKUP_DIR && \
            ssh $ADDRESS "apk update && apk add postgresql && PGPASSWORD=homeassistant pg_dumpall --data-only --disable-triggers -h 77b2833f-timescaledb -U postgres --file $BACKUP_FILE" && \
        scp $ADDRESS:$BACKUP_FILE . && \
        ssh $ADDRESS rm -f $BACKUP_FILE && \
        echo "BACKUP DONE"

    # notify HA
    [ $? -eq 0 ] && WEBHOOK_ID="backing-up-confirmations-ookLyJMLbyruY" || WEBHOOK_ID="backing-up-confirmations-OZ6WisQ9"
    curl -X POST -H "Content-Type: application/json" -d '{ "backup_name": "'$BACKUP_NAME'" }' http://192.168.0.202:8123/api/webhook/$WEBHOOK_ID

    find . -name '*.dump' -type f -mtime +10 -delete
    ```

# Dropping old TimescaleDB chunks

If you want to drop some older data to save DB size, you can do that via the following command:

    SELECT drop_chunks('ltss', INTERVAL '1 month');

and manually validate that they got dropped by checking the table size:

    SELECT
    schema_name,
    relname,
    pg_size_pretty(table_size) AS size,
    table_size

    FROM (
        SELECT
            pg_catalog.pg_namespace.nspname           AS schema_name,
            relname,
            pg_relation_size(pg_catalog.pg_class.oid) AS table_size

        FROM pg_catalog.pg_class
            JOIN pg_catalog.pg_namespace ON relnamespace = pg_catalog.pg_namespace.oid
        ) t
    WHERE schema_name NOT LIKE 'pg_%'
    ORDER BY table_size DESC;
