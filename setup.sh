#!/bin/bash
set -euo pipefail

# ==============================================
#  AWS-VPN: Xray VLESS Reality + WS+TLS+CDN
#  One-click deployment script
# ==============================================

DOMAIN="illrq.vip"
REALITY_PORT=443
CDN_PORT=8443
REALITY_DEST="www.microsoft.com:443"
REALITY_SERVER_NAMES="www.microsoft.com"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ----------------------------------------------
# 0. Check prerequisites
# ----------------------------------------------
check_command() {
    command -v "$1" >/dev/null 2>&1
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: Please run as root (sudo bash setup.sh)"
    exit 1
fi

if ! check_command docker; then
    echo "Docker not found. Install with:"
    echo "  curl -fsSL https://get.docker.com | sh"
    exit 1
fi

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif check_command docker-compose; then
    COMPOSE_CMD="docker-compose"
else
    echo "Docker Compose not found. Install Docker with:"
    echo "  curl -fsSL https://get.docker.com | sh"
    exit 1
fi

# Check if ports are available
for PORT in ${REALITY_PORT} ${CDN_PORT}; do
    if ss -tlnp | grep -q ":${PORT} "; then
        echo "Error: Port ${PORT} is already in use."
        ss -tlnp | grep ":${PORT} "
        exit 1
    fi
done

# ----------------------------------------------
# 1. Create directories
# ----------------------------------------------
mkdir -p "${SCRIPT_DIR}/xray"

# ----------------------------------------------
# 2. Pull image and generate secrets
# ----------------------------------------------
echo "Pulling Xray image..."
docker pull teddysun/xray:latest

echo "Generating secrets..."

# UUID
UUID=$(docker run --rm teddysun/xray:latest xray uuid)

# x25519 keypair for Reality
KEYS_OUTPUT=$(docker run --rm teddysun/xray:latest xray x25519)
PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | grep "Public key:" | awk '{print $3}')

# Short ID (8-byte hex)
SHORT_ID=$(openssl rand -hex 8)

# Random WebSocket path
WS_PATH="/$(openssl rand -hex 8)"

# Detect server public IP
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
# 3. Generate self-signed certificate for WS+TLS
# ----------------------------------------------
echo "Generating self-signed certificate for ${DOMAIN}..."
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -nodes \
    -keyout "${SCRIPT_DIR}/xray/key.pem" \
    -out "${SCRIPT_DIR}/xray/cert.pem" \
    -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN}" \
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
            "listen": "0.0.0.0",
            "port": ${REALITY_PORT},
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
            "tag": "ws-tls-in",
            "listen": "0.0.0.0",
            "port": ${CDN_PORT},
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
                "security": "tls",
                "tlsSettings": {
                    "certificates": [
                        {
                            "certificateFile": "/etc/xray/cert.pem",
                            "keyFile": "/etc/xray/key.pem"
                        }
                    ]
                },
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
# 5. Save configuration to .env
# ----------------------------------------------
cat > "${SCRIPT_DIR}/.env" << ENV_EOF
UUID=${UUID}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
SERVER_IP=${SERVER_IP}
DOMAIN=${DOMAIN}
REALITY_PORT=${REALITY_PORT}
CDN_PORT=${CDN_PORT}
REALITY_SERVER_NAMES=${REALITY_SERVER_NAMES}
REALITY_DEST=${REALITY_DEST}
WS_PATH=${WS_PATH}
ENV_EOF
chmod 600 "${SCRIPT_DIR}/.env"

# ----------------------------------------------
# 6. Configure firewall (if available)
# ----------------------------------------------
if check_command ufw; then
    echo "Configuring UFW firewall..."
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow ${REALITY_PORT}/tcp >/dev/null 2>&1
    ufw allow ${CDN_PORT}/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
elif check_command firewall-cmd; then
    echo "Configuring firewalld..."
    firewall-cmd --permanent --add-port=22/tcp >/dev/null 2>&1
    firewall-cmd --permanent --add-port=${REALITY_PORT}/tcp >/dev/null 2>&1
    firewall-cmd --permanent --add-port=${CDN_PORT}/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
fi

# ----------------------------------------------
# 7. Start the service
# ----------------------------------------------
echo "Starting Xray..."
cd "${SCRIPT_DIR}"
${COMPOSE_CMD} up -d

# Wait and check if container is running
sleep 2
if docker ps | grep -q xray; then
    echo ""
    echo "========================================="
    echo "  Xray deployed successfully!"
    echo "========================================="
    echo ""
    bash "${SCRIPT_DIR}/show-client-info.sh"
else
    echo ""
    echo "Error: Xray container failed to start."
    echo "Check logs: docker logs xray"
    exit 1
fi
