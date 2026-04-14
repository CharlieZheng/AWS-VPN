#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Stopping Xray..."

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    docker stop xray 2>/dev/null || true
    docker rm xray 2>/dev/null || true
    COMPOSE_CMD=""
fi

if [ -n "$COMPOSE_CMD" ]; then
    cd "${SCRIPT_DIR}"
    ${COMPOSE_CMD} down 2>/dev/null || true
fi

echo "Removing generated files..."
rm -rf "${SCRIPT_DIR}/xray"
rm -f "${SCRIPT_DIR}/.env"

echo ""
echo "Uninstall complete."
echo "Docker image retained. To remove: docker rmi teddysun/xray"
