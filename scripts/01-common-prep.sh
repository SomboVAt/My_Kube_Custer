#!/bin/bash
set -euo pipefail

HOSTNAME="${1:-cp01.company.local}"
HOST_IP="${2:-192.168.10.11}"

if [[ "$EUID" -ne 0 ]]; then
	echo "Run this script as root (for example, with sudo)." >&2
	exit 1
fi

case "$HOSTNAME:$HOST_IP" in
	cp01.company.local:192.168.10.11|cp02.company.local:192.168.10.12|cp03.company.local:192.168.10.13|worker01.company.local:192.168.10.21|worker02.company.local:192.168.10.22|worker03.company.local:192.168.10.23) ;;
	*)
		echo "Unknown node or hostname/IP mismatch: $HOSTNAME $HOST_IP" >&2
		exit 2
		;;
esac

hostnamectl set-hostname "$HOSTNAME"

cat > /etc/hosts <<EOF
127.0.0.1 localhost localhost.localdomain localhost4 localhost4.localdomain4
::1 localhost localhost.localdomain localhost6 localhost6.localdomain6

192.168.10.11 cp01.company.local cp01
192.168.10.12 cp02.company.local cp02
192.168.10.13 cp03.company.local cp03
192.168.10.21 worker01.company.local worker01
192.168.10.22 worker02.company.local worker02
192.168.10.23 worker03.company.local worker03
192.168.10.100 kubernetes-api.company.local kubernetes-api
192.168.10.111 oda
EOF

dnf update -y
dnf install -y vim curl wget socat conntrack chrony
systemctl enable --now chronyd

swapoff -a
sed -i '/swap/s/^/#/' /etc/fstab

setenforce 0
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system

echo "Common prep complete for $HOSTNAME"
