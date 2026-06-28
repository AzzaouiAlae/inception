#!/bin/sh

echo "=== Starting WordPress Setup ==="

addgroup -g 2000 $LINUX_GROUP_NAME 2>/dev/null || true
adduser -D -u 2000 -G $LINUX_GROUP_NAME -s /bin/sh $LINUX_USER_NAME 2>/dev/null || true

if [ ! -f "/etc/php84/php-fpm.conf" ]; then
  echo '[www]
  user = '$LINUX_USER_NAME'
  group = '$LINUX_GROUP_NAME'
  listen = wordpress:'$PHP_FPM_PORT'
  pm = dynamic
  pm.max_children = 5
  pm.start_servers = 2
  pm.min_spare_servers = 1
  pm.max_spare_servers = 3
  clear_env = no
  ' > /etc/php84/php-fpm.conf
fi

mkdir -p /var/www/html
cp /app/wp-config.php /var/www/html/wp-config.php

if [ ! -f "/var/www/html/index.php" ]; then

  cd /var/www

  wget https://wordpress.org/latest.tar.gz
  tar -xzf latest.tar.gz
  rm latest.tar.gz
  cp -r wordpress/* html/
  rm -rf wordpress

  cd /var/www/html

  chown -R $LINUX_USER_NAME:$LINUX_GROUP_NAME /var/www/html
  chmod -R 755 /var/www/html

  echo "=== Waiting for MariaDB to be ready ==="

  i=0
  until mariadb -h mariadb -P "${MARIADB_PORT}" -u "$WP_DB_USER" \
        -p"$(cat /run/secrets/db_password)" -e 'SELECT 1' "$DB_NAME" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
      echo "ERROR: MariaDB still not reachable after 60 attempts, aborting." >&2
      exit 1
    fi
    echo "MariaDB not ready yet (attempt $i/60)..."
    sleep 1
  done

  echo "=== Starting WordPress Users Creation ==="

  WP_ADMIN_PASSWORD=$(cat /run/secrets/wp_admin_password)

  wp core install \
    --url="${USER_HOST}" \
    --title="Inception" \
    --admin_user="${WP_ADMIN}" \
    --admin_password="${WP_ADMIN_PASSWORD}" \
    --admin_email="${WP_ADMIN}@${USER_HOST_EMAIL}" \
    --skip-email \
    --allow-root


  WP_USER_PASSWORD=$(cat /run/secrets/wp_user_password)
  wp user create ${USER} ${USER}@${USER_HOST_EMAIL} --role=editor --user_pass="$WP_USER_PASSWORD" --allow-root

  EDITOR_ID=$(wp user get ${USER} --field=ID --allow-root)
  wp post update 1 --post_author="$EDITOR_ID" --allow-root

  wp theme install twentytwentyfour --activate --allow-root

  wp plugin install redis-cache --activate --allow-root
  wp redis enable --allow-root

  chown -R $LINUX_USER_NAME:$LINUX_GROUP_NAME /var/www/html

  echo "=== WordPress Setup Complete ==="
fi

exec php-fpm84 -F
