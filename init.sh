set -xe

postgres_data="/data"

# Ensure permissions are correct on the data directory
echo ${POSTGRES_PASSWORD} >password.txt
chown -R postgres:postgres password.txt
chown -R postgres:postgres "${postgres_data}"
chmod 700 "${postgres_data}"

# Check if the data directory is empty
if [ -z "$(ls -A "${postgres_data}")" ]; then
    echo "Initializing database..."

    # Initialize the database
    su - postgres -c 'initdb -D /data -A md5 --pwfile=/password.txt'

    # Configure shared_preload_libraries, adding timescaledb
    sed -r -i "s/^[#]*\s*(shared_preload_libraries)\s*=\s*'(.*)'/\1 = 'timescaledb,\2'/" "${postgres_data}/postgresql.conf"

    # Set Password protect for IPv4 hosts and local connections
    {
        echo "host    all             all             0.0.0.0/0               md5"
        echo "local   all             all                                      md5"
        echo "local   all             all                                     peer"
    } >>"${postgres_data}/pg_hba.conf"

    # Set Listen on all addresses (*)
    sed -r -i "s/^[#]*\s*listen_addresses\s*=\s*'.*'/listen_addresses = '*'/" "${postgres_data}/postgresql.conf"

    # Set telemetry level and license key
    echo "timescaledb.telemetry_level='off'" >>"${postgres_data}/postgresql.conf"
    echo "timescaledb.license_key='CommunityLicense'" >>"${postgres_data}/postgresql.conf"
    echo "shared_preload_libraries = 'timescaledb'" >>"${postgres_data}/postgresql.conf"
else
    echo "Database directory is not empty, skipping initialization."
fi

# Start the PostgreSQL server
su - postgres -c 'postgres -D /data'
