# AWS-VPN

Xray VLESS 双协议代理，Docker 一键部署。

- **主力**：VLESS + Reality（外网端口 443，直连，速度快）
- **备用**：VLESS + WS + TLS + Cloudflare CDN（外网端口同为 443，SNI 分流，IP 被封也能用）

## 快速开始

### 服务器端

```bash
# 安装 Docker（如未安装）
curl -fsSL https://get.docker.com | sh

# 克隆并部署
git clone <repo-url> && cd AWS-VPN
sudo bash setup.sh

# 可选：开启 BBR TCP 加速
sudo bash bbr.sh
```

### AWS 安全组

放行入站规则：
- TCP 22（SSH）
- TCP 443（所有流量统一走 443：Reality / Web / WS 都通过 Nginx SNI 分流）

### Cloudflare 设置（WS+CDN 备用线路必需）

1. 将域名 `illrq.vip` 添加到 Cloudflare（在域名注册商处修改 NS 记录）
2. DNS 记录：
   - 类型：**A**
   - 名称：`@`（即 `illrq.vip`）
   - 内容：EC2 公网 IP
   - 代理状态：**已代理**（橙色云朵开启）
3. SSL/TLS > 概述 > 加密模式：**Full**（不是 "Full (Strict)"）
4. 网络 > WebSockets：**开启**

### 客户端设置

`setup.sh` 执行完成后会自动输出双协议的分享链接。也可以随时运行：

```bash
bash show-client-info.sh
```

复制 VLESS 分享链接导入客户端：

| 平台 | 推荐客户端 |
|------|-----------|
| Windows | v2rayN |
| macOS | V2rayU、Clash Verge |
| Android | v2rayNG |
| iOS | Shadowrocket |
| Linux | Clash Meta (mihomo) |

**日常使用 Reality-Direct（快）。如果连不上，切换到 WS-CDN-Backup。**

## 脚本说明

| 脚本 | 用途 |
|------|------|
| `setup.sh` | 一键部署（生成密钥、证书、配置，启动服务） |
| `show-client-info.sh` | 查看客户端连接信息和分享链接 |
| `bbr.sh` | 开启 BBR TCP 拥塞控制（可选，推荐） |
| `uninstall.sh` | 停止服务并清理生成的文件 |

## 日常管理

```bash
# 查看日志
docker logs xray

# 重启服务
docker restart xray

# 更新 Xray
docker compose pull && docker compose up -d

# 查看状态
docker ps | grep xray
```

## 故障排查

**Reality 连不上：**
- 检查 AWS 安全组是否放行了 TCP 443
- 运行 `docker logs xray` 查看错误
- 确认服务器 IP 没有被封（从非中国网络测试）

**WS+CDN 连不上：**
- 确认 Cloudflare DNS 已开启代理（橙色云朵）
- 确认 SSL 模式为 "Full"（不是 "Flexible" 也不是 "Full Strict"）
- 确认 Cloudflare 网络设置中 WebSockets 已开启
- 检查 AWS 安全组是否放行了 TCP 443

**服务器 IP 被封：**
- 客户端切换到 WS-CDN-Backup 链接即可
- 可选：释放并重新分配 AWS Elastic IP，更新 Cloudflare A 记录，重新运行 `setup.sh`
