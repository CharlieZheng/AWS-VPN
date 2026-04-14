#!/bin/bash
set -euo pipefail

# ==============================================
#  Enable BBR TCP congestion control
#  Improves throughput, especially on high-latency links
# ==============================================

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: Please run as root (sudo bash bbr.sh)"
    exit 1
fi

# Check kernel version (BBR requires 4.9+)
KERNEL_MAJOR=$(uname -r | cut -d. -f1)
KERNEL_MINOR=$(uname -r | cut -d. -f2)

if [ "$KERNEL_MAJOR" -lt 4 ] || { [ "$KERNEL_MAJOR" -eq 4 ] && [ "$KERNEL_MINOR" -lt 9 ]; }; then
    echo "Error: BBR requires Linux kernel 4.9+. Current: $(uname -r)"
    exit 1
fi

# Check if already enabled
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
if [ "$CURRENT_CC" = "bbr" ]; then
    echo "BBR is already enabled."
    exit 0
fi

echo "Enabling BBR..."

# Load BBR module
modprobe tcp_bbr 2>/dev/null || true

# Apply sysctl settings
cat >> /etc/sysctl.conf << 'EOF'

# BBR TCP Congestion Control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF

# Ensure module loads at boot
echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf

# Apply immediately
sysctl --system >/dev/null 2>&1

echo ""
echo "BBR enabled successfully."
echo "  Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "  Queue discipline:   $(sysctl -n net.core.default_qdisc)"
