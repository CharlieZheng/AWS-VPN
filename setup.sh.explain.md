# setup.sh 逐行解释

## 第 1-2 行：脚本头部

```bash
#!/bin/bash
set -euo pipefail
```

- `#!/bin/bash` — 指定用 bash 解释器执行此脚本。
- `set -euo pipefail` — 启用严格模式：
  - `-e`：任何命令执行失败（返回非零）立即退出脚本，防止错误被忽略。
  - `-u`：使用未定义的变量时报错退出，防止拼写错误导致空值。
  - `-o pipefail`：管道命令中任一步骤失败，整个管道返回失败。默认只看最后一步。

---

## 第 4-7 行：注释块

```bash
# ==============================================
#  AWS-VPN: Xray VLESS Reality + WS+TLS+CDN
#  One-click deployment script
# ==============================================
```

纯注释，说明脚本用途。

---

## 第 9-13 行：全局配置变量

```bash
DOMAIN="illrq.vip"
LISTEN_PORT=443
REALITY_DEST="www.microsoft.com:443"
REALITY_SERVER_NAMES="www.microsoft.com"

# Internal ports (localhost only, not exposed to internet)
XRAY_REALITY_PORT=10443
XRAY_WS_PORT=10000
NGINX_HTTPS_PORT=10080
```

- `DOMAIN` — 你的域名，用于 WS+TLS+CDN 备用线路（通过 Cloudflare）和自签名证书。
- `LISTEN_PORT=443` — **对外唯一端口**。所有流量统一走 443，由 Nginx 根据 SNI 分流到不同后端。
- `REALITY_DEST` — Reality 伪装目标。当 GFW 主动探测你的服务器时，Reality 会将探测请求转发到 microsoft.com，让探测者看到的是一个正常的微软网站。
- `REALITY_SERVER_NAMES` — TLS 握手时允许的 SNI（Server Name Indication）。客户端连接时会带上这个域名，Xray 据此判断是否为合法客户端。
- `XRAY_REALITY_PORT` — Xray Reality 入站监听在本机回环地址（127.0.0.1）的端口（仅供 Nginx 转发）。
- `XRAY_WS_PORT` — Xray WS 入站监听在本机回环地址（127.0.0.1）的端口（TLS 由 Nginx 终止）。
- `NGINX_HTTPS_PORT` — Nginx 的本机 HTTPS 站点端口（仅本机监听），用于承载网站与 WS 反代入口。

---

## 第 15 行：获取脚本所在目录

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
```

- `$0` — 当前脚本的路径（如 `./setup.sh` 或 `/root/AWS-VPN/setup.sh`）。
- `dirname "$0"` — 取目录部分（如 `.` 或 `/root/AWS-VPN`）。
- `cd ... && pwd` — 进入该目录后用 `pwd` 取绝对路径。
- 这样无论从哪里执行脚本，后续的文件操作都用绝对路径，不会出错。

---

## 第 20-22 行：辅助函数

```bash
check_command() {
    command -v "$1" >/dev/null 2>&1
}
```

- `command -v "$1"` — 检查系统是否存在某个命令（比 `which` 更可靠）。
- `>/dev/null 2>&1` — 丢弃所有输出，只关心返回码（0=存在，非0=不存在）。
- 后面多次调用 `check_command docker`、`check_command ufw` 等。

---

## 第 24-27 行：检查 root 权限

```bash
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: Please run as root (sudo bash setup.sh)"
    exit 1
fi
```

- `id -u` — 返回当前用户的 UID。root 的 UID 是 0。
- `-ne 0` — 不等于 0，即非 root。
- 需要 root 权限是因为要绑定 443 端口（低于 1024 的端口需要 root）和配置防火墙。

---

## 第 29-33 行：检查 Docker

```bash
if ! check_command docker; then
    echo "Docker not found. Install with:"
    echo "  curl -fsSL https://get.docker.com | sh"
    exit 1
fi
```

Docker 未安装则给出安装命令并退出。不自动安装是为了让用户知情并控制安装过程。

---

## 第 35-43 行：检查 Docker Compose

```bash
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif check_command docker-compose; then
    COMPOSE_CMD="docker-compose"
else
    echo "Docker Compose not found. Install Docker with:"
    echo "  curl -fsSL https://get.docker.com | sh"
    exit 1
fi
```

- Docker Compose 有两种形式：
  - `docker compose`（V2，作为 Docker 插件，新版默认）
  - `docker-compose`（V1，独立二进制，旧版）
- 优先使用 V2，回退到 V1，都没有则报错。
- 将命令存入 `COMPOSE_CMD` 变量，后面统一调用。

---

## 第 46-52 行：检查端口占用

```bash
if ss -tlnp | grep -q ":${LISTEN_PORT} "; then
    echo "Error: Port ${LISTEN_PORT} is already in use."
    ss -tlnp | grep ":${LISTEN_PORT} "
    exit 1
fi
```

- `ss -tlnp` — 列出所有 TCP 监听端口（`-t` TCP，`-l` 监听，`-n` 数字格式，`-p` 显示进程）。
- `grep -q ":443 "` — 静默检查 443 端口是否被占用。
- 如果 443 已被其他服务占用（如已有 Nginx、Apache），提前报错，避免容器启动失败。

---

## 第 57 行：创建目录

```bash
mkdir -p "${SCRIPT_DIR}/xray"
```

- `-p` — 目录已存在时不报错。
- 创建 `xray/` 目录，用于存放 config.json、证书和私钥。

---

## 第 62-63 行：拉取 Docker 镜像

```bash
echo "Pulling Xray image..."
docker pull teddysun/xray:latest
```

- 从 Docker Hub 拉取 `teddysun/xray` 镜像。这是一个基于 Alpine Linux 的轻量镜像，内含 xray-core。
- 先拉取是因为后面要用这个镜像的 xray 命令来生成密钥。

---

## 第 68 行：生成 UUID

```bash
UUID=$(docker run --rm teddysun/xray:latest xray uuid)
```

- `docker run --rm` — 运行一个临时容器，执行完立即删除。
- `xray uuid` — Xray 内置的 UUID 生成命令，输出一个标准的 UUID v4（如 `a1b2c3d4-e5f6-...`）。
- UUID 是客户端连接时的身份凭证，相当于密码。每次运行 setup.sh 都会生成新的。

---

## 第 71-73 行：生成 x25519 密钥对

```bash
KEYS_OUTPUT=$(docker run --rm teddysun/xray:latest xray x25519)
PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | grep "Public key:" | awk '{print $3}')
```

- `xray x25519` — 生成一对 x25519 椭圆曲线密钥，输出格式为：
  ```
  Private key: xxxxxx
  Public key:  yyyyyy
  ```
- `grep + awk` — 分别提取私钥和公钥。
- **私钥**放在服务端配置中，**公钥**给客户端。这是 Reality 协议的核心——客户端用公钥验证服务器身份，防止中间人攻击。

---

## 第 76 行：生成 Short ID

```bash
SHORT_ID=$(openssl rand -hex 8)
```

- `openssl rand -hex 8` — 生成 8 字节随机数并以十六进制表示（16 个字符）。
- Short ID 是 Reality 协议的额外认证参数。客户端必须带上匹配的 Short ID 才能通过验证。相当于第二道密码。

---

## 第 79 行：生成随机 WebSocket 路径

```bash
WS_PATH="/$(openssl rand -hex 8)"
```

- 生成一个随机路径（如 `/a3f8b2c1d4e5f607`）。
- WS+TLS 的 WebSocket 连接使用这个路径。随机路径防止被扫描发现——只有知道正确路径的客户端才能建立 WebSocket 连接，其他路径的请求会被拒绝。

---

## 第 83-85 行：检测服务器公网 IP

```bash
SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me || \
            curl -4 -s --max-time 5 icanhazip.com || \
            curl -4 -s --max-time 5 ipinfo.io/ip)
```

- 依次尝试三个公网 IP 检测服务，用 `||` 连接表示前一个失败才试下一个。
- `-4` — 强制使用 IPv4。
- `-s` — 静默模式，不显示进度条。
- `--max-time 5` — 每个请求最多等 5 秒。
- 获取到的 IP 用于生成客户端配置（Reality 直连需要知道服务器 IP）。

---

## 第 87-90 行：IP 检测失败处理

```bash
if [ -z "$SERVER_IP" ]; then
    echo "Error: Could not detect server public IP."
    exit 1
fi
```

- `-z` — 字符串为空则为真。
- 三个服务都失败（如网络未通），退出并报错。

---

## 第 98-104 行：生成自签名证书

```bash
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -nodes \
    -keyout "${SCRIPT_DIR}/xray/key.pem" \
    -out "${SCRIPT_DIR}/xray/cert.pem" \
    -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN}" \
    2>/dev/null
```

- `req -x509` — 生成自签名证书（不需要 CA 签发）。
- `-newkey ec -pkeyopt ec_paramgen_curve:prime256v1` — 使用 P-256 椭圆曲线生成密钥，比 RSA 更小更快。
- `-days 3650` — 有效期 10 年，不用担心过期。
- `-nodes` — 私钥不加密（No DES），Xray 启动时不需要输入密码。
- `-keyout` / `-out` — 私钥和证书的输出路径。
- `-subj "/CN=${DOMAIN}"` — 证书的 Common Name 设为域名。
- `-addext "subjectAltName=DNS:${DOMAIN}"` — SAN 扩展，现代 TLS 要求。
- `2>/dev/null` — 隐藏 openssl 的进度输出。
- 这个证书用于 WS+TLS inbound。因为 Cloudflare SSL 模式设为 "Full"（不是 "Full Strict"），不会验证证书的有效性，所以自签名就够了。

---

## 第 110-205 行：生成 Xray 配置文件

```bash
cat > "${SCRIPT_DIR}/xray/config.json" << XRAY_EOF
...
XRAY_EOF
```

- `cat > file << XRAY_EOF` — Here Document 语法，将多行内容写入文件，直到遇到 `XRAY_EOF` 结束。
- 配置文件是 JSON 格式，包含以下主要部分：

### log（第 112-114 行）

```json
"log": { "loglevel": "warning" }
```

日志级别设为 warning，只记录警告和错误。避免 debug/info 级别产生大量日志暴露使用痕迹。

### inbounds[0]：Reality 入站（第 116-154 行）

- `"tag": "reality-in"` — 标识名，用于日志和路由。
- `"listen": "0.0.0.0"` — 监听所有网络接口。
- `"port": 443` — 监听 443 端口。
- `"protocol": "vless"` — 使用 VLESS 协议（比 VMess 更轻量，无需加密层因为 Reality 已提供）。
- `"id": "${UUID}"` — 客户端认证用的 UUID。
- `"flow": "xtls-rprx-vision"` — 启用 XTLS Vision 流控。Vision 解决了早期 XTLS 的"TLS-in-TLS"特征问题，让代理流量在外观上与普通 TLS 流量完全一致。
- `"decryption": "none"` — VLESS 本身不加密（加密由 Reality/TLS 层处理）。
- `"network": "tcp"` — 传输层使用原始 TCP（Vision flow 只支持 TCP）。
- `"security": "reality"` — 启用 Reality 安全层。
- `"dest": "www.microsoft.com:443"` — 伪装目标。非法连接（如 GFW 探测）会被转发到微软服务器，返回真实的微软网页。
- `"xver": 0` — 不使用 PROXY Protocol。
- `"serverNames"` — 允许的 TLS SNI 列表。客户端握手时 SNI 必须匹配。
- `"privateKey"` — x25519 私钥，服务端持有。
- `"shortIds"` — 额外认证 ID 列表。
- `"sniffing"` — 流量嗅探，从 TLS SNI / HTTP Host 中检测真实目标地址，用于正确路由和 DNS 解析。

### inbounds[1]：WS 入站（第 155-192 行）

- `"tag": "ws-in"` — 标识名。
- `"listen": "127.0.0.1"` — 只监听本机回环，不对外暴露。
- `"port": 10000` — 本机 WS 入站端口（示例，实际由 `XRAY_WS_PORT` 决定）。
- `"flow": ""` — WS 传输不支持 flow，必须留空。
- `"network": "ws"` — 传输层使用 WebSocket。
- `"security": "none"` — TLS 由 Nginx 终止，Xray 侧不再配置 TLS。
- `"path": "${WS_PATH}"` — WebSocket 握手路径，只有匹配的请求才会被处理。

### outbounds（第 194-203 行）

```json
"outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
]
```

- `freedom` — 直接连接目标网站（正常出站）。
- `blackhole` — 丢弃流量（可配合路由规则屏蔽特定流量）。

---

## 第 210-223 行：保存配置到 .env

```bash
cat > "${SCRIPT_DIR}/.env" << ENV_EOF
UUID=${UUID}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
...
ENV_EOF
chmod 600 "${SCRIPT_DIR}/.env"
```

- 将所有生成的密钥和配置参数保存到 `.env` 文件，供 `show-client-info.sh` 读取。
- `chmod 600` — 只有文件所有者（root）可读写，其他用户无权访问。保护密钥安全。

---

## 第 228-240 行：配置防火墙

```bash
if check_command ufw; then
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow ${LISTEN_PORT}/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
elif check_command firewall-cmd; then
    firewall-cmd --permanent --add-port=22/tcp >/dev/null 2>&1
    ...
fi
```

- 检测系统使用的防火墙工具（Ubuntu 用 ufw，CentOS/RHEL 用 firewalld）。
- 放行 SSH（22）和 443（所有对外流量统一走 443）。
- `ufw --force enable` — 强制启用 ufw，跳过交互确认。
- `firewall-cmd --permanent` — 永久生效（重启不丢失）。
- AWS 本身有安全组（Security Group），相当于云端防火墙。这里配置的是系统级防火墙，双重保障。

---

## 第 245-263 行：启动服务

```bash
echo "Starting Xray..."
cd "${SCRIPT_DIR}"
${COMPOSE_CMD} up -d
```

- `cd` 到脚本目录，因为 Docker Compose 需要在 `docker-compose.yml` 所在目录执行。
- `up -d` — 创建并启动容器，`-d` 表示后台运行。

```bash
sleep 2
if docker ps | grep -q xray; then
    ...
    bash "${SCRIPT_DIR}/show-client-info.sh"
else
    echo "Error: Xray container failed to start."
    echo "Check logs: docker logs xray"
    exit 1
fi
```

- `sleep 2` — 等 2 秒让容器完全启动。
- `docker ps | grep xray` — 检查 xray 容器是否在运行。
- 成功则调用 `show-client-info.sh` 输出客户端连接信息。
- 失败则提示查看日志排查原因。
