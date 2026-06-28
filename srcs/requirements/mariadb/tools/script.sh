#!/bin/sh

echo "Starting MariaDB server setup..."

# 1. ALWAYS recreate the configuration file so it's fresh
echo "Writing MariaDB configuration file..."
echo '[server]
[mysqld]
datadir = /var/lib/mysql
port = '${MARIADB_PORT}'
bind-address=mariadb
[galera]
[embedded]
[mariadb]
[mariadb-10.5]
' > /etc/my.cnf

# 2. Check the PERSISTENT VOLUME directory, not the temporary cnf file
if [ ! -d /var/lib/mysql/mysql ]; then
    echo "Volume is empty! Initializing MariaDB system tables..."
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql

    echo "Creating initialization SQL script..."
    DB_PASSWORD=$(cat /run/secrets/db_password)
    DB_ROOT_PASSWORD=$(cat /run/secrets/db_root_password)

    echo "CREATE DATABASE IF NOT EXISTS ${DB_NAME};
    CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'%' IDENTIFIED BY '$DB_PASSWORD';
    GRANT SELECT, INSERT, UPDATE, DELETE, ALTER, CREATE, DROP, INDEX, REFERENCES ON ${DB_NAME}.* TO '${WP_DB_USER}'@'%';
    ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
    FLUSH PRIVILEGES;" > /tmp/init.sql

    echo "Starting MariaDB with initialization setup..."
    exec mariadbd --user=mysql --datadir=/var/lib/mysql --init-file=/tmp/init.sql
else
    echo "Database data detected in named volume. Skipping initialization."
    echo "Starting MariaDB in the foreground..."
    exec mariadbd --user=mysql --datadir=/var/lib/mysql
fi