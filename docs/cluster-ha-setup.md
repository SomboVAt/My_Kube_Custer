# Kubernetes HA Cluster Setup

This repository documents a Kubernetes high-availability cluster built with:

- 3 control-plane nodes
- 3 worker nodes
- VIP: 192.168.10.100
- HAProxy + Keepalived on the control-plane nodes
- Oracle Linux 10
- Kubernetes v1.37

## Architecture

| Hostname | IP | Role |
| --- | --- | --- |
| cp01.company.local | 192.168.10.11 | Control plane + HAProxy + Keepalived |
| cp02.company.local | 192.168.10.12 | Control plane + HAProxy + Keepalived |
| cp03.company.local | 192.168.10.13 | Control plane + HAProxy + Keepalived |
| worker01.company.local | 192.168.10.21 | Worker |
| worker02.company.local | 192.168.10.22 | Worker |
| worker03.company.local | 192.168.10.23 | Worker |
| kubernetes-api.company.local | 192.168.10.100 | API VIP |

## Prerequisites

- Oracle Linux 10 on all nodes
- Network connectivity between all nodes
- Hostnames and hosts file correctly configured
- Firewall and SELinux adjusted for lab use

## Common node preparation

Run this on every node, changing the hostname and IP for each host.

```bash
#!/bin/bash
set -euo pipefail

hostnamectl set-hostname cp01.company.local

cat >> /etc/hosts <<EOF
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
```

## Install containerd

```bash
dnf install -y dnf-utils
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y containerd.io

containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
```

## Install Kubernetes packages

```bash
cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.37/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.37/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
systemctl enable --now kubelet
```

## Firewall rules

### Control plane nodes

```bash
firewall-cmd --permanent --add-port={6443,2379-2380,10250,10257,10259}/tcp
firewall-cmd --permanent --add-port=8404/tcp
firewall-cmd --permanent --add-service=vrrp
firewall-cmd --reload
```

### Worker nodes

```bash
firewall-cmd --permanent --add-port={10250,30000-32767}/tcp
firewall-cmd --reload
```

## HAProxy config

Install HAProxy:

```bash
dnf install -y haproxy
```

Create `/etc/haproxy/haproxy.cfg`:

```bash
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
```

Enable non-local bind:

```bash
echo "net.ipv4.ip_nonlocal_bind = 1" > /etc/sysctl.d/99-vip.conf
sysctl --system
```

## Keepalived config

Install Keepalived:

```bash
dnf install -y keepalived
```

Example config for cp01:

```bash
vrrp_script check_haproxy {
    script "pidof haproxy"
    interval 2
    weight 2
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    state MASTER
    interface ens160
    virtual_router_id 51
    priority 100
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
```

For cp02 and cp03, change only:

- `state` to `BACKUP`
- `priority` to `90` for cp02 and `80` for cp03

Start services:

```bash
systemctl enable --now haproxy keepalived
haproxy -c -f /etc/haproxy/haproxy.cfg
ip -br a | grep 192.168.10.100
```

## Initialize cluster on cp01

```bash
kubeadm init \
  --control-plane-endpoint="kubernetes-api.company.local:6443" \
  --apiserver-advertise-address=192.168.10.11 \
  --upload-certs \
  --pod-network-cidr=10.244.0.0/16
```

Configure kubectl:

```bash
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes
```

Install CNI:

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

## Join cp02 and cp03

Run the control-plane join command from the `kubeadm init` output on each additional control-plane node:

```bash
sudo kubeadm join kubernetes-api.company.local:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --control-plane \
  --certificate-key <CERT_KEY> \
  --apiserver-advertise-address=192.168.10.12
```

For cp03 use 192.168.10.13 as the advertise address.

## Join workers

```bash
sudo kubeadm join kubernetes-api.company.local:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

## Validate cluster

```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system
```

## Notes

- Replace `ens160` with the actual NIC name if different.
- Validate network names with `ip -br a`.
- Check firewall rules if nodes do not communicate.
- If a token expires, use `kubeadm token create --print-join-command` on the control plane.

## GitHub workflow

This repository is intended to be pushed to GitHub for version control and automation.

```bash
git init
git branch -M main
git add .
git commit -m "Initial Kubernetes HA cluster setup"
git remote add origin https://github.com/<your-user>/<your-repo>.git
git push -u origin main
```
