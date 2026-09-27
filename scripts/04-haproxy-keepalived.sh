#!/bin/bash
set -euo pipefail

INTERFACE="${1:-ens160}"
STATE="${2:-MASTER}"
PRIORITY="${3:-100}"

if ! command -v haproxy >/dev/null 2>&1; then
  dnf install -y haproxy
fi

if ! command -v keepalived >/dev/null 2>&1; then
  dnf install -y keepalived
fi

cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local2
    chroot /var/lib/haproxy
    pidfile /var/run/haproxy.pid
    maxconn 4000
    user haproxy
    group haproxy
    daemon
    stats socket /var/lib/haproxy/stats

defaults
    mode tcp
    log global
    option tcplog
    option dontlognull
    option redispatch
    retries 3
    timeout queue 1m
    timeout connect 10s
    timeout check 5s
    timeout client 86400s
    timeout server 86400s
    timeout http-request 10s
    maxconn 3000

frontend k8s-api
    bind 192.168.10.100:6443
    mode tcp
    option tcplog
    default_backend k8s-api

backend k8s-api
    mode tcp
    balance roundrobin
    option tcp-check
    server cp01 192.168.10.11:6443 check fall 3 rise 2
    server cp02 192.168.10.12:6443 check fall 3 rise 2
    server cp03 192.168.10.13:6443 check fall 3 rise 2

listen haproxy-stats
    mode http
    bind *:8404
    stats enable
    stats uri /
    stats refresh 5s
    stats auth admin:Root@120
EOF

echo "net.ipv4.ip_nonlocal_bind = 1" > /etc/sysctl.d/99-vip.conf
sysctl --system

cat > /etc/keepalived/keepalived.conf <<EOF
vrrp_script check_haproxy {
    script "pidof haproxy"
    interval 2
    weight 2
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    state $STATE
    interface $INTERFACE
    virtual_router_id 51
    priority $PRIORITY
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass K8sHA@2025
    }
    virtual_ipaddress {
        192.168.10.100/24
    }
    track_script {
        check_haproxy
    }
}
EOF

systemctl enable --now haproxy keepalived
haproxy -c -f /etc/haproxy/haproxy.cfg

echo "HAProxy and Keepalived configured"
