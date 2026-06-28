#!/bin/bash
set -e 

SECRETS_DIR="srcs/secrets"

echo "=== Starting Secrets Setup ==="

# 1. Create the secrets directory early
if [ ! -d "$SECRETS_DIR" ]; then
    mkdir -p "$SECRETS_DIR"

    # 2. Check for mkcert, download locally if missing
    if command -v mkcert &> /dev/null; then
        MKCERT_BIN="mkcert"
    elif [ -f "./mkcert" ]; then
        MKCERT_BIN="./mkcert"
    else
        echo "[!] mkcert not found. Downloading locally..."
        curl -JLO "https://dl.filippo.io/mkcert/latest?for=linux/amd64"
        chmod +x mkcert-v*-linux-amd64
        mv mkcert-v*-linux-amd64 mkcert
        MKCERT_BIN="./mkcert"
    fi

    # 3. Generate TLS certificates only if they don't exist
    echo "[+] Generating TLS certificates..."
    $MKCERT_BIN -install 
    $MKCERT_BIN -key-file "$SECRETS_DIR/nginx.key" -cert-file "$SECRETS_DIR/nginx.crt" "${USER}.42.fr" 127.0.0.1
    

    # 4. Generate database secrets if missing
    echo "[+] Generating database password..."
    openssl rand -base64 24 > "$SECRETS_DIR/db_password.txt"
    
    echo "[+] Generating database root password..."
    openssl rand -base64 24 > "$SECRETS_DIR/db_root_password.txt"
    
    echo "[+] Generating WordPress user password..."
    openssl rand -base64 10 > "$SECRETS_DIR/wp_user_password.txt"
    
    echo "[+] Generating WordPress admin password..."
    openssl rand -base64 10 > "$SECRETS_DIR/wp_admin_password.txt"

    echo "[+] Generating FTP password..."
    openssl rand -base64 10 > "$SECRETS_DIR/ftp_password.txt"

    echo "[+] Generating grafana password..."
    openssl rand -base64 10 > "$SECRETS_DIR/grafana_password.txt"

    # 5. Generate WordPress salts if missing
    echo "[+] Fetching wordpress salts..."
    curl -s https://api.wordpress.org/secret-key/1.1/salt/ > "$SECRETS_DIR/salts.txt"
    

    # 6. Create volume folders (mkdir -p is already idempotent)
    echo "[+] Checking volume folders..."
    mkdir -p "$HOME/data/mariadb"
    mkdir -p "$HOME/data/wordpress"
    mkdir -p "$HOME/data/prometheus"

    # Optional: Clean up the local binary
    rm ./mkcert 2>/dev/null || true
fi

echo "=== Setup Complete! ==="