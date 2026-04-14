#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Stopping services..."

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    docker stop xray nginx 2>/dev/null || true
    docker rm xray nginx 2>/dev/null || true
    COMPOSE_CMD=""
fi

if [ -n "$COMPOSE_CMD" ]; then
    cd "${SCRIPT_DIR}"
    ${COMPOSE_CMD} down 2>/dev/null || true
fi

echo "Removing generated files..."
rm -rf "${SCRIPT_DIR}/xray"
rm -rf "${SCRIPT_DIR}/nginx"
rm -f "${SCRIPT_DIR}/.env"

echo ""
echo "Uninstall complete."
echo "Docker images retained. To remove:"
echo "  docker rmi teddysun/xray nginx:stable"
