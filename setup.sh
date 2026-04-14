#!/bin/bash
set -euo pipefail

# ==============================================
#  AWS-VPN: Xray VLESS Reality + WS+TLS+CDN
#  Nginx SNI routing + Xray dual inbound
# ==============================================

on_error() {
    local exit_code=$?
    echo "" >&2
    echo "Error: setup failed (exit=${exit_code})." >&2
    echo "  line: ${BASH_LINENO[0]}" >&2
    echo "  cmd:  ${BASH_COMMAND}" >&2
    echo "" >&2
    echo "Hint: run with 'DEBUG=1 bash setup.sh' (or add sudo if needed) to show full command trace." >&2
    exit "${exit_code}"
}
trap on_error ERR

if [ "${DEBUG:-0}" = "1" ]; then
    set -x
fi

DOMAIN="illrq.vip"
LISTEN_PORT=443
REALITY_DEST="www.microsoft.com:443"
REALITY_SERVER_NAMES="www.microsoft.com"

# Internal ports (localhost only, not exposed to internet)
XRAY_REALITY_PORT=10443
XRAY_WS_PORT=10000
NGINX_HTTPS_PORT=10080

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ----------------------------------------------
# 0. Check prerequisites
# ----------------------------------------------
check_command() {
    command -v "$1" >/dev/null 2>&1
}

IS_ROOT=0
if [ "$(id -u)" -eq 0 ]; then
    IS_ROOT=1
fi

SUDO=""
if [ "${IS_ROOT}" -ne 1 ] && check_command sudo; then
    SUDO="sudo"
fi

if ! check_command docker; then
    echo "Docker not found. Install with:"
    echo "  curl -fsSL https://get.docker.com | sh"
    exit 1
fi

DOCKER_BIN="docker"
if [ "${IS_ROOT}" -ne 1 ]; then
    if docker version >/dev/null 2>&1; then
        DOCKER_BIN="docker"
    elif [ -n "${SUDO}" ] && ${SUDO} docker version >/dev/null 2>&1; then
        DOCKER_BIN="${SUDO} docker"
        echo "Info: docker requires sudo on this host; using '${DOCKER_BIN}'." >&2
    else
        echo "Error: cannot access Docker daemon." >&2
        echo "  If you see 'permission denied ... /var/run/docker.sock', run:" >&2
        echo "    sudo bash setup.sh" >&2
        echo "  Or add your user to the 'docker' group, re-login, then rerun." >&2
        exit 1
    fi
fi

if ${DOCKER_BIN} compose version >/dev/null 2>&1; then
    COMPOSE_CMD="${DOCKER_BIN} compose"
elif check_command docker-compose; then
    if [ "${DOCKER_BIN}" = "docker" ]; then
        COMPOSE_CMD="docker-compose"
    else
        COMPOSE_CMD="${SUDO} docker-compose"
    fi
else
    echo "Docker Compose not found."
    exit 1
fi

if ss -tlnp | grep -q ":${LISTEN_PORT} "; then
    echo "Error: Port ${LISTEN_PORT} is already in use."
    ss -tlnp | grep ":${LISTEN_PORT} "
    exit 1
fi

# ----------------------------------------------
# 1. Create directories
# ----------------------------------------------
mkdir -p "${SCRIPT_DIR}/xray"
mkdir -p "${SCRIPT_DIR}/nginx"
mkdir -p "${SCRIPT_DIR}/www/html"

# ----------------------------------------------
# 2. Pull images and generate secrets
# ----------------------------------------------
echo "Pulling Docker images..."
${DOCKER_BIN} pull teddysun/xray:latest
${DOCKER_BIN} pull nginx:alpine

echo "Generating secrets..."

UUID=$(${DOCKER_BIN} run --rm teddysun/xray:latest xray uuid)

KEYS_OUTPUT=$(${DOCKER_BIN} run --rm teddysun/xray:latest xray x25519)
PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | grep "Public key:" | awk '{print $3}')

SHORT_ID=$(openssl rand -hex 8)
WS_PATH="/$(openssl rand -hex 8)"

echo "Detecting server IP..."
SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me || \
            curl -4 -s --max-time 5 icanhazip.com || \
            curl -4 -s --max-time 5 ipinfo.io/ip)

if [ -z "$SERVER_IP" ]; then
    echo "Error: Could not detect server public IP."
    exit 1
fi

echo "Server IP: ${SERVER_IP}"

# ----------------------------------------------
# 3. Generate self-signed certificate (wildcard)
# ----------------------------------------------
echo "Generating self-signed certificate..."
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -nodes \
    -keyout "${SCRIPT_DIR}/xray/key.pem" \
    -out "${SCRIPT_DIR}/xray/cert.pem" \
    -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN}" \
    2>/dev/null

# ----------------------------------------------
# 4. Generate Xray config (dual inbound)
# ----------------------------------------------
echo "Generating Xray configuration..."
cat > "${SCRIPT_DIR}/xray/config.json" << XRAY_EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "tag": "reality-in",
            "listen": "127.0.0.1",
            "port": ${XRAY_REALITY_PORT},
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${UUID}",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${REALITY_DEST}",
                    "xver": 0,
                    "serverNames": [
                        "${REALITY_SERVER_NAMES}"
                    ],
                    "privateKey": "${PRIVATE_KEY}",
                    "shortIds": [
                        "${SHORT_ID}"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ]
            }
        },
        {
            "tag": "ws-in",
            "listen": "127.0.0.1",
            "port": ${XRAY_WS_PORT},
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${UUID}",
                        "flow": ""
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "ws",
                "security": "none",
                "wsSettings": {
                    "path": "${WS_PATH}"
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}
XRAY_EOF

# ----------------------------------------------
# 5. Generate Nginx config (SNI routing)
# ----------------------------------------------
echo "Generating Nginx configuration..."

cat > "${SCRIPT_DIR}/nginx/nginx.conf" << 'NGINX_EOF'
load_module /etc/nginx/modules/ngx_stream_module.so;

worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

stream {
    map $ssl_preread_server_name $backend {
        __REALITY_SNI__         reality;
        __DOMAIN__              web;
        __SUBDOMAIN_PATTERN__   web;
        default                 reality;
    }

    upstream reality {
        server 127.0.0.1:__XRAY_REALITY_PORT__;
    }

    upstream web {
        server 127.0.0.1:__NGINX_HTTPS_PORT__;
    }

    server {
        listen __LISTEN_PORT__ reuseport;
        proxy_pass $backend;
        ssl_preread on;
        proxy_connect_timeout 5s;
        proxy_timeout 300s;
    }
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log off;

    server {
        listen 127.0.0.1:__NGINX_HTTPS_PORT__ ssl;
        http2 on;
        server_name __DOMAIN__ *.__DOMAIN__;

        ssl_certificate /etc/nginx/ssl/cert.pem;
        ssl_certificate_key /etc/nginx/ssl/key.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;

        # Xray WebSocket proxy
        location __WS_PATH__ {
            proxy_pass http://127.0.0.1:__XRAY_WS_PORT__;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
        }

        # Default website
        location / {
            root /var/www/html;
            index index.html;
        }
    }

    # --- Add subdomains below ---
    # Example: sudoku.illrq.vip
    #
    # server {
    #     listen 127.0.0.1:__NGINX_HTTPS_PORT__ ssl;
    #     http2 on;
    #     server_name sudoku.__DOMAIN__;
    #     ssl_certificate /etc/nginx/ssl/cert.pem;
    #     ssl_certificate_key /etc/nginx/ssl/key.pem;
    #     ssl_protocols TLSv1.2 TLSv1.3;
    #     root /var/www/sudoku;
    #     index index.html;
    # }
}
NGINX_EOF

# Fill in placeholders (order matters: SUBDOMAIN_PATTERN before DOMAIN)
DOMAIN_REGEX=$(echo "${DOMAIN}" | sed 's/\./\\./g')
sed -i "s|__REALITY_SNI__|${REALITY_SERVER_NAMES}|g" "${SCRIPT_DIR}/nginx/nginx.conf"
sed -i "s|__SUBDOMAIN_PATTERN__|~^.+\\.${DOMAIN_REGEX}\$|g" "${SCRIPT_DIR}/nginx/nginx.conf"
sed -i "s|__DOMAIN__|${DOMAIN}|g" "${SCRIPT_DIR}/nginx/nginx.conf"
sed -i "s|__WS_PATH__|${WS_PATH}|g" "${SCRIPT_DIR}/nginx/nginx.conf"
sed -i "s|__LISTEN_PORT__|${LISTEN_PORT}|g" "${SCRIPT_DIR}/nginx/nginx.conf"
sed -i "s|__XRAY_REALITY_PORT__|${XRAY_REALITY_PORT}|g" "${SCRIPT_DIR}/nginx/nginx.conf"
sed -i "s|__XRAY_WS_PORT__|${XRAY_WS_PORT}|g" "${SCRIPT_DIR}/nginx/nginx.conf"
sed -i "s|__NGINX_HTTPS_PORT__|${NGINX_HTTPS_PORT}|g" "${SCRIPT_DIR}/nginx/nginx.conf"

# ----------------------------------------------
# 6. Create default website (if not exists)
# ----------------------------------------------
if [ ! -f "${SCRIPT_DIR}/www/html/index.html" ]; then
    cat > "${SCRIPT_DIR}/www/html/index.html" << 'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
</head>
<body>
    <h1>Welcome</h1>
    <p>Site under construction.</p>
</body>
</html>
HTML_EOF
fi

# ----------------------------------------------
# 7. Save configuration to .env
# ----------------------------------------------
cat > "${SCRIPT_DIR}/.env" << ENV_EOF
UUID=${UUID}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
SERVER_IP=${SERVER_IP}
DOMAIN=${DOMAIN}
PORT=${LISTEN_PORT}
REALITY_SERVER_NAMES=${REALITY_SERVER_NAMES}
REALITY_DEST=${REALITY_DEST}
WS_PATH=${WS_PATH}
ENV_EOF
chmod 600 "${SCRIPT_DIR}/.env"

# ----------------------------------------------
# 8. Configure firewall (if available)
# ----------------------------------------------
if check_command ufw; then
    echo "Configuring firewall..."
    if [ "${IS_ROOT}" -eq 1 ]; then
        ufw allow 22/tcp >/dev/null 2>&1
        ufw allow ${LISTEN_PORT}/tcp >/dev/null 2>&1
        ufw --force enable >/dev/null 2>&1
    elif [ -n "${SUDO}" ]; then
        ${SUDO} ufw allow 22/tcp >/dev/null 2>&1
        ${SUDO} ufw allow ${LISTEN_PORT}/tcp >/dev/null 2>&1
        ${SUDO} ufw --force enable >/dev/null 2>&1
    else
        echo "Warning: ufw detected but no permission to modify firewall; skipping." >&2
    fi
elif check_command firewall-cmd; then
    echo "Configuring firewall..."
    if [ "${IS_ROOT}" -eq 1 ]; then
        firewall-cmd --permanent --add-port=22/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port=${LISTEN_PORT}/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif [ -n "${SUDO}" ]; then
        ${SUDO} firewall-cmd --permanent --add-port=22/tcp >/dev/null 2>&1
        ${SUDO} firewall-cmd --permanent --add-port=${LISTEN_PORT}/tcp >/dev/null 2>&1
        ${SUDO} firewall-cmd --reload >/dev/null 2>&1
    else
        echo "Warning: firewalld detected but no permission to modify firewall; skipping." >&2
    fi
fi

# ----------------------------------------------
# 9. Start services
# ----------------------------------------------
echo "Starting services..."
cd "${SCRIPT_DIR}"
${COMPOSE_CMD} up -d

sleep 3
XRAY_OK=$(${DOCKER_BIN} ps --filter name=xray --filter status=running -q)
NGINX_OK=$(${DOCKER_BIN} ps --filter name=nginx --filter status=running -q)

if [ -n "$XRAY_OK" ] && [ -n "$NGINX_OK" ]; then
    echo ""
    echo "========================================="
    echo "  Deployment successful!"
    echo "========================================="
    echo ""
    bash "${SCRIPT_DIR}/show-client-info.sh"
else
    echo ""
    echo "Error: Some containers failed to start."
    [ -z "$XRAY_OK" ] && echo "  Xray:  FAILED (check: docker logs xray)"
    [ -z "$NGINX_OK" ] && echo "  Nginx: FAILED (check: docker logs nginx)"
    exit 1
fi
