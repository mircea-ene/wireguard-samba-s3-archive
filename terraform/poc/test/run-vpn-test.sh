#!/bin/bash
# Runs templates/vpn-user-data.sh in a systemd Ubuntu 24.04 container
# (Docker runs inside it, like on EC2), then checks that wg-easy came up with
# the unattended settings and hands out a split-tunnel device config.
# Usage: ./run-vpn-test.sh [--keep]
set -euo pipefail
cd "$(dirname "$0")"
MVP="$(cd .. && pwd)"
VPN=poc-vpn-test
KEEP="${1:-}"
PASSWORD='Test-Wg_Pass1!xyz'

cleanup() {
  [ "$KEEP" = "--keep" ] && { echo "kept container $VPN"; return; }
  docker rm -f -v "$VPN" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker rm -f "$VPN" >/dev/null 2>&1 || true

docker build -q -t poc-systemd-test -f Dockerfile.systemd . >/dev/null
docker run -d --name "$VPN" --privileged --cgroupns=host --security-opt apparmor=unconfined \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
  -v /var/lib/docker -v /var/lib/containerd \
  poc-systemd-test >/dev/null
sleep 3
docker cp "$MVP/templates/vpn-user-data.sh" "$VPN:/vpn-user-data.sh"

echo "--- running vpn-user-data.sh"
docker exec \
  -e AWS_REGION=eu-central-1 -e WG_HOST=203.0.113.10 \
  -e WG_ALLOWED_IPS=172.31.0.0/16 -e WG_DNS=172.31.0.2 -e WG_EASY_IMAGE=ghcr.io/wg-easy/wg-easy:15.5.0 \
  -e WG_ADMIN_USER=admin -e WG_ADMIN_PASSWORD="$PASSWORD" \
  "$VPN" bash /vpn-user-data.sh > vpn-user-data.log 2>&1 \
  || { echo "vpn-user-data.sh FAILED, last lines:"; tail -30 vpn-user-data.log; exit 1; }
echo "vpn-user-data.sh OK (full log: test/vpn-user-data.log)"

docker exec -i -e P="$PASSWORD" "$VPN" bash -s <<'EOF'
set -uo pipefail
pass=0; fail=0
t() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PASS  $d"; pass=$((pass+1)); else echo "FAIL  $d"; fail=$((fail+1)); fi; }
api=http://127.0.0.1:51821/api
for _ in $(seq 1 30); do curl -s -o /dev/null "$api/client" && break; sleep 2; done
t "docker enabled at boot"            systemctl is-enabled docker
t "wg-easy container running"         bash -c 'docker inspect -f "{{.State.Running}}" wg-easy | grep -q true'
t "wg-easy restarts after reboot"     bash -c 'docker inspect -f "{{.HostConfig.RestartPolicy.Name}}" wg-easy | grep -q unless-stopped'
t ".env readable by root only"        bash -c '[ "$(stat -c %a /opt/wg-easy/.env)" = 600 ]'
t "ip forwarding on"                  bash -c '[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ]'
t "UI login with admin password"      bash -c 'curl -sf -u "admin:$P" '"$api"'/client'
t "UI refuses wrong password"         bash -c '! curl -sf -u "admin:wrong" '"$api"'/client'
t "create a device"                   bash -c 'curl -sf -u "admin:$P" -H "Content-Type: application/json" -d "{\"name\":\"test-laptop\",\"expiresAt\":null}" '"$api"'/client'
cfg="$(curl -s -u "admin:$P" "$api/client/1/configuration")"
echo "$cfg" | sed 's/^PrivateKey.*/PrivateKey = (hidden)/; s/^PresharedKey.*/PresharedKey = (hidden)/; s/^/      /'
t "device config: split tunnel (VPC only)" grep -q '^AllowedIPs = 172.31.0.0/16$' <<<"$cfg"
t "device config: endpoint is the EIP"     grep -q '^Endpoint = 203.0.113.10:51820$' <<<"$cfg"
t "device config: DNS is the VPC resolver"  grep -q '^DNS = 172.31.0.2$' <<<"$cfg"
t "device config: plain WireGuard (no AmneziaWG)" bash -c '! grep -qE "^(Jc|S1|H1) " <<<"$1"' _ "$cfg"
t "wg0 interface up in container"     docker exec wg-easy wg show wg0
if [ "$fail" != 0 ]; then
  echo "--- wg-easy logs (for debugging failures)"
  docker logs --tail 40 wg-easy 2>&1 | sed "s/^/      /"
fi
echo; echo "checks: $pass passed, $fail failed"
[ "$fail" = 0 ]
EOF
