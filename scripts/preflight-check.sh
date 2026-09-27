#!/bin/bash
set -euo pipefail

HOSTNAME="${1:-$(hostname)}"
IP="${2:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
VIP="${VIP:-192.168.10.100}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() {
  echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

fail() {
  echo -e "${RED}[FAIL]${NC} $1"
  exit 1
}

check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "$1 is installed"
  else
    fail "$1 is required but not installed"
  fi
}

echo "===== Kubernetes VM Preflight Check ====="

echo "Hostname: $HOSTNAME"
echo "Node IP: $IP"
echo "VIP: $VIP"

check_cmd hostname
check_cmd ip
check_cmd ping

if [ "$(hostname)" = "$HOSTNAME" ]; then
  pass "Hostname matches expected value"
else
  warn "Current hostname is $(hostname); expected $HOSTNAME"
fi

if ip addr show >/dev/null 2>&1; then
  pass "Network interfaces are available"
else
  fail "No network interfaces detected"
fi

IFACE=$(ip -o -4 addr show | awk -v expected="$IP" '{split($4, address, "/"); if (address[1] == expected) {print $2; exit}}')
if [ -n "$IP" ] && [ -n "$IFACE" ]; then
  pass "Expected IP $IP is configured on interface $IFACE"
else
  warn "Expected IP $IP is not configured on a network interface"
fi

if [ -n "$IP" ] && grep -E "^${IP}[[:space:]]+${HOSTNAME}" /etc/hosts >/dev/null 2>&1; then
  pass "/etc/hosts contains this node's hostname and IP"
else
  warn "/etc/hosts does not include this node's hostname/IP yet"
fi

for node in \
  cp01.company.local \
  cp02.company.local \
  cp03.company.local \
  worker01.company.local \
  worker02.company.local \
  worker03.company.local; do
  if getent hosts "$node" >/dev/null 2>&1; then
    pass "DNS/hosts entry found for $node"
  else
    warn "DNS/hosts entry missing for $node"
  fi
done

if ping -c 1 "$VIP" >/dev/null 2>&1; then
  pass "VIP $VIP is reachable"
else
  warn "VIP $VIP is not reachable yet; HAProxy/Keepalived may not be configured"
fi

if command -v firewall-cmd >/dev/null 2>&1; then
  if firewall-cmd --state >/dev/null 2>&1; then
    pass "firewalld is available and running"
  else
    warn "firewalld is installed but not running"
  fi
else
  warn "firewalld is not available or not installed"
fi

if [ -f /etc/modules-load.d/k8s.conf ]; then
  pass "kubernetes module config exists"
else
  warn "kubernetes module config is missing"
fi

if [ -f /etc/sysctl.d/k8s.conf ]; then
  pass "kubernetes sysctl config exists"
else
  warn "kubernetes sysctl config is missing"
fi

if swapon --show=NAME --noheading 2>/dev/null | grep -q .; then
  warn "Swap is still enabled"
else
  pass "Swap is disabled"
fi

echo "===== Preflight Summary ====="
echo "Review all WARN lines before running kubeadm init."

echo "Tip: run on each VM with the correct hostname and IP, for example:"
echo "  bash preflight-check.sh cp01.company.local 192.168.10.11"
echo "  bash preflight-check.sh cp02.company.local 192.168.10.12"
