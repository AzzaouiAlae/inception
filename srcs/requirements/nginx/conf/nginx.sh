#!/bin/sh

if [ ! -f "/etc/nginx/nginx.conf" ]; then
    echo 'user '$LINUX_USER_NAME';

    events {
        worker_connections 1024;
    }

    http {
            include /etc/nginx/mime.types;
            sendfile on;
            tcp_nopush on;
            ssl_protocols TLSv1.2 TLSv1.3;
            ssl_prefer_server_ciphers on;
            ssl_session_timeout 1h;
            ssl_session_tickets off;
            gzip_vary on;

            server {
                listen '$NGINX_PORT' ssl;
                server_name '$USER_HOST';
                root /var/www/html;
                index index.php index.html;

                ssl_certificate     /run/secrets/nginx_crt;
                ssl_certificate_key /run/secrets/nginx_key;
                ssl_session_cache   shared:SSL:10m;
                add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

                location = / {
                    try_files $uri $uri/ /index.php?$args;
                }

                location ~ \.php$ {
                    fastcgi_pass wordpress:'$PHP_FPM_PORT';
                    fastcgi_index index.php;
                    include fastcgi_params;
                    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                }

                location /resume/ {
                    # The trailing slash here is EXTREMELY important
                    proxy_pass http://resume:5000/;
            
                    # These headers pass important information about the original request 
                    # to your backend application
                    proxy_set_header Host $host;
                    proxy_set_header X-Real-IP $remote_addr;
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                    proxy_set_header X-Forwarded-Proto $scheme;
                }

                location /adminer/ {
                    proxy_pass http://adminer:'$ADMINER_PORT'/;
                    proxy_set_header Host $host;
                    proxy_set_header X-Real-IP $remote_addr;
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                    proxy_set_header X-Forwarded-Proto $scheme;
                }

                location /grafana/ {
                    proxy_pass http://grafana:'$GRAFANA_PORT';
                    proxy_set_header Host $host;
                    proxy_set_header X-Real-IP $remote_addr;
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                    proxy_set_header X-Forwarded-Proto $scheme;
                    # WebSocket support (Grafana live updates)
                    proxy_http_version 1.1;
                    proxy_set_header Upgrade $http_upgrade;
                    proxy_set_header Connection "upgrade";
                }
            }
    }' > /etc/nginx/nginx.conf
fi

exec nginx -g 'daemon off;'