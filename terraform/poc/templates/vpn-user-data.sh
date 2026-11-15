#!/bin/bash
# VPN server setup: WireGuard managed by wg-easy (Docker).
#
# Terraform prepends `export` lines for the variables below. Plain bash, no
# Terraform template syntax, so it can be tested in Docker.
#
# Required:  AWS_REGION WG_HOST WG_ALLOWED_IPS WG_EASY_IMAGE WG_ADMIN_USER
#            WG_ADMIN_PASSWORD_PARAM (or WG_ADMIN_PASSWORD)
# Optional:  WG_PORT WG_UI_PORT WG_CLIENT_CIDR WG_DNS
#
# Test seams (never set on EC2):
#   WG_ADMIN_PASSWORD   skip the SSM lookup
#   SKIP_CONTAINER_START=1  write the config but do not start wg-easy
set -euo pipefail
exec > >(tee -a /var/log/vpn-setup.log) 2>&1
echo "=== VPN setup started $(date -Is)"

: "${AWS_REGION:?}" "${WG_HOST:?}" "${WG_ALLOWED_IPS:?}" "${WG_EASY_IMAGE:?}" "${WG_ADMIN_USER:?}"
WG_PORT="${WG_PORT:-51820}"
WG_UI_PORT="${WG_UI_PORT:-51821}"
WG_CLIENT_CIDR="${WG_CLIENT_CIDR:-10.8.0.0/24}"
WG_DNS="${WG_DNS:-1.1.1.1}"
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -q -o DPkg::Lock::Timeout=600"

$APT update
$APT install --no-install-recommends docker.io docker-compose-v2 curl unzip ca-certificates

if [ -z "${WG_ADMIN_PASSWORD:-}" ]; then
  if ! command -v aws >/dev/null; then
    curl -fsSL -o /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip"
    unzip -q -o /tmp/awscliv2.zip -d /tmp && /tmp/aws/install --update
  fi
  WG_ADMIN_PASSWORD="$(aws ssm get-parameter --region "$AWS_REGION" --name "${WG_ADMIN_PASSWORD_PARAM:?}" \
    --with-decryption --query Parameter.Value --output text)"
fi

# Routing between the tunnel and the VPC (also set inside the container).
cat > /etc/sysctl.d/90-wireguard.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
EOF
sysctl --system >/dev/null || true

mkdir -p /opt/wg-easy/data
cd /opt/wg-easy

# INIT_* values are applied only on first start (empty database). After
# that, everything is managed from the web UI.
umask 077
cat > .env <<EOF
PORT=$WG_UI_PORT
# PoC: the UI is plain HTTP, restricted by the security group to one address.
INSECURE=true
DISABLE_IPV6=true
INIT_ENABLED=true
INIT_USERNAME=$WG_ADMIN_USER
INIT_PASSWORD=$WG_ADMIN_PASSWORD
INIT_HOST=$WG_HOST
INIT_PORT=$WG_PORT
INIT_IPV4_CIDR=$WG_CLIENT_CIDR
INIT_DNS=$WG_DNS
INIT_ALLOWED_IPS=$WG_ALLOWED_IPS
EOF
unset WG_ADMIN_PASSWORD
umask 022

cat > compose.yml <<EOF
services:
  wg-easy:
    image: $WG_EASY_IMAGE
    container_name: wg-easy
    restart: unless-stopped
    env_file: .env
    ports:
      - "$WG_PORT:$WG_PORT/udp"
      - "$WG_UI_PORT:$WG_UI_PORT/tcp"
    volumes:
      - ./data:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
EOF

systemctl enable --now docker
if [ "${SKIP_CONTAINER_START:-0}" != "1" ]; then
  docker compose pull
  docker compose up -d
fi

touch /var/lib/vpn-setup.done
echo "=== VPN setup finished $(date -Is)"
