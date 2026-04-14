#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "${SCRIPT_DIR}/.env" ]; then
    echo "Error: .env not found. Run setup.sh first."
    exit 1
fi

source "${SCRIPT_DIR}/.env"

# VLESS Reality share link (direct connection)
REALITY_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAMES}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Reality-Direct"

# VLESS WS+TLS+CDN share link (via Cloudflare)
CDN_LINK="vless://${UUID}@${DOMAIN}:${PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=$(echo "${WS_PATH}" | sed 's|/|%2F|g')&allowInsecure=1#WS-CDN-Backup"

echo ""
echo "============================================"
echo "  [1] Reality Direct (Primary - Fast)"
echo "============================================"
echo ""
echo "Protocol:    VLESS"
echo "Address:     ${SERVER_IP}"
echo "Port:        ${PORT}"
echo "UUID:        ${UUID}"
echo "Flow:        xtls-rprx-vision"
echo "Network:     tcp"
echo "Security:    reality"
echo "SNI:         ${REALITY_SERVER_NAMES}"
echo "Fingerprint: chrome"
echo "Public Key:  ${PUBLIC_KEY}"
echo "Short ID:    ${SHORT_ID}"
echo ""
echo "Share Link:"
echo "${REALITY_LINK}"
echo ""

echo "============================================"
echo "  [2] WS+TLS+CDN (Backup - Anti-block)"
echo "============================================"
echo ""
echo "Protocol:    VLESS"
echo "Address:     ${DOMAIN}"
echo "Port:        ${PORT}"
echo "UUID:        ${UUID}"
echo "Network:     ws"
echo "Security:    tls"
echo "SNI:         ${DOMAIN}"
echo "WS Path:     ${WS_PATH}"
echo "Fingerprint: chrome"
echo ""
echo "Share Link:"
echo "${CDN_LINK}"
echo ""

echo "============================================"
echo "  Clash Meta / Mihomo Config"
echo "============================================"
echo ""
cat << CLASH_EOF
proxies:
  - name: Reality-Direct
    type: vless
    server: ${SERVER_IP}
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    servername: ${REALITY_SERVER_NAMES}

  - name: WS-CDN-Backup
    type: vless
    server: ${DOMAIN}
    port: ${PORT}
    uuid: ${UUID}
    network: ws
    tls: true
    udp: true
    skip-cert-verify: true
    client-fingerprint: chrome
    servername: ${DOMAIN}
    ws-opts:
      path: ${WS_PATH}
      headers:
        Host: ${DOMAIN}
CLASH_EOF

echo ""
echo "============================================"
echo "  Client Setup Guide"
echo "============================================"
echo ""
echo "v2rayN / v2rayNG / Shadowrocket:"
echo "  Copy the Share Link above and import from clipboard."
echo ""
echo "Cloudflare Setup (required for WS+CDN backup):"
echo "  1. Add domain '${DOMAIN}' to Cloudflare"
echo "  2. A record: ${DOMAIN} -> ${SERVER_IP} (Proxied/Orange cloud ON)"
echo "  3. SSL/TLS -> Full (NOT Full Strict)"
echo "  4. Network -> WebSockets: ON"
echo ""

# QR codes if qrencode is available
if command -v qrencode >/dev/null 2>&1; then
    echo "============================================"
    echo "  QR Code - Reality Direct"
    echo "============================================"
    echo ""
    echo "${REALITY_LINK}" | qrencode -t ANSIUTF8
    echo ""
    echo "============================================"
    echo "  QR Code - WS+CDN Backup"
    echo "============================================"
    echo ""
    echo "${CDN_LINK}" | qrencode -t ANSIUTF8
    echo ""
else
    echo "(Install qrencode for QR codes: apt install qrencode / yum install qrencode)"
fi
