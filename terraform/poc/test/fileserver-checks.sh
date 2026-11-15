#!/bin/bash
# Runs inside the test container after fileserver-user-data.sh.
set -uo pipefail
pass=0; fail=0
ok()   { echo "PASS  $1"; pass=$((pass+1)); }
bad()  { echo "FAIL  $1"; fail=$((fail+1)); }
t()    { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

echo "--- services"
t "smbd running"                       systemctl is-active smbd
t "nmbd not running"                   bash -c '! systemctl is-active nmbd'
t "cockpit socket listening"           systemctl is-active cockpit.socket
t "iperf3 server running"              systemctl is-active iperf3-poc
t "archive mount team-a running"    systemctl is-active rclone-archive@team-a
t "archive mount team-b running"    systemctl is-active rclone-archive@team-b
t "archive mounts enabled at boot"     systemctl is-enabled rclone-archive@team-a
t "rclone is current, not Ubuntu 1.60" bash -c '! rclone version | head -1 | grep -q "v1.60"'
t "Cockpit Identities installed"       dpkg -s cockpit-identities
t "Cockpit Files installed"            dpkg -s cockpit-files
t "Cockpit from backports (>314)"      bash -c '[ "$(dpkg-query -W -f="\${Version}" cockpit | cut -d- -f1)" -gt 314 ]'
t "admin user has sudo"                bash -c 'id -nG fsadmin | grep -qw sudo'
t "Cockpit login with admin password"  bash -c 'curl -sk -u "fsadmin:Test-Admin_Pass1!" -o /dev/null -w "%{http_code}" https://localhost:9090/cockpit/login | grep -q 200'
t "Cockpit refuses wrong password"     bash -c 'curl -sk -u "fsadmin:wrong" -o /dev/null -w "%{http_code}" https://localhost:9090/cockpit/login | grep -q 401'
t "iperf3 reachable on 5201"           bash -c 'iperf3 -c 127.0.0.1 -t 1 | grep -q receiver'
t "smb.conf valid"                     testparm -s
if [ "${DATA_DEVICE:-none}" != none ]; then
  t "/srv is the data volume (xfs)"    bash -c 'findmnt -n -o FSTYPE /srv | grep -q xfs'
  t "/srv in fstab with nofail"        grep -q ' /srv xfs defaults,nofail' /etc/fstab
  t "fstab entry not duplicated"       bash -c '[ "$(grep -c " /srv xfs" /etc/fstab)" = 1 ]'
fi
t "archive file visible via mount"     test -f /srv/archive/team-a/contracts/contract.txt
t "add-zone helper works"              /usr/local/sbin/fileserver-add-zone team-c
t "add-zone rejects bad names"         bash -c '! /usr/local/sbin/fileserver-add-zone "../etc"'

echo "--- share permissions (share-permissions.sh with throwaway users)"
for u in alice:team-a bob:team-b carol:team-a,team-b; do
  name="${u%%:*}"; groups="${u##*:}"
  id "$name" >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin -G "staff,$groups" "$name"
  printf 'test1234\ntest1234\n' | smbpasswd -s -a "$name" >/dev/null
done
if bash /share-permissions.sh; then ok "share permission suite"; else bad "share permission suite"; fi

echo; echo "checks: $pass passed, $fail failed"
[ "$fail" = 0 ]
