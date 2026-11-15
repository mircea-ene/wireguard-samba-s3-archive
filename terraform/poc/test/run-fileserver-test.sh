#!/bin/bash
# Runs templates/fileserver-user-data.sh in a systemd Ubuntu 24.04 container, against a
# fake S3 (rclone serve s3) holding test/fake-s3, then checks:
#   - every service the script sets up is running
#   - the share permission tests from share-permissions.sh (with throwaway
#     test users created here only, not by the user-data script)
# Usage: ./run-fileserver-test.sh [--keep]
set -euo pipefail
cd "$(dirname "$0")"
MVP="$(cd .. && pwd)"
FAKE_S3="$(cd fake-s3 && pwd)"
NET=poc-test
SRV=poc-fileserver-test
S3=poc-fakes3-test
KEEP="${1:-}"

cleanup() {
  [ "$KEEP" = "--keep" ] && { echo "kept containers $SRV and $S3"; return; }
  docker exec "$SRV" bash -c 'umount -l /srv 2>/dev/null; losetup -D 2>/dev/null' >/dev/null 2>&1 || true
  docker rm -f "$SRV" "$S3" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker rm -f "$SRV" "$S3" >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true

docker build -q -t poc-systemd-test -f Dockerfile.systemd . >/dev/null
docker network create "$NET" >/dev/null
docker run -d --name "$S3" --network "$NET" -v "$FAKE_S3:/data:ro" rclone/rclone:latest \
  serve s3 /data --addr :9000 --auth-key poc-key,poc-secret-123 >/dev/null
docker run -d --name "$SRV" --network "$NET" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --device /dev/fuse \
  --tmpfs /run --tmpfs /run/lock poc-systemd-test >/dev/null
sleep 3

# Test seam: rclone config pointing at the fake S3 (the script keeps it).
docker exec -i "$SRV" bash -c 'mkdir -p /etc/rclone && cat > /etc/rclone/rclone.conf' <<'EOF'
[archive]
type = s3
provider = Other
endpoint = http://poc-fakes3-test:9000
access_key_id = poc-key
secret_access_key = poc-secret-123
region = us-east-1
EOF

# Stand-in for the EBS volume: a loop device, so the format/fstab/mount path runs.
DATA_DEVICE="$(docker exec "$SRV" bash -c 'truncate -s 2G /ebs.img && losetup -f --show /ebs.img' 2>/dev/null || echo none)"
echo "data device: $DATA_DEVICE"

docker cp "$MVP/templates/fileserver-user-data.sh" "$SRV:/fileserver-user-data.sh"
docker cp share-permissions.sh "$SRV:/share-permissions.sh"
docker cp fileserver-checks.sh "$SRV:/fileserver-checks.sh"

echo "--- running fileserver-user-data.sh (takes a few minutes)"
start=$(date +%s)
docker exec \
  -e AWS_REGION=eu-central-1 -e ARCHIVE_BUCKET=archive-test \
  -e ZONES="team-a team-b" -e ADMIN_USER=fsadmin \
  -e ADMIN_PASSWORD='Test-Admin_Pass1!' -e DATA_DEVICE="$DATA_DEVICE" \
  -e RCLONE_CACHE_MAX_SIZE=1G \
  -e COCKPIT_IDENTITIES_DEB_URL="https://github.com/45Drives/cockpit-identities/releases/download/v0.1.14-1/cockpit-identities_0.1.14-1jammy_all.deb" \
  "$SRV" bash /fileserver-user-data.sh > fileserver-user-data.log 2>&1 \
  || { echo "fileserver-user-data.sh FAILED, last lines:"; tail -30 fileserver-user-data.log; exit 1; }
echo "fileserver-user-data.sh finished in $(( $(date +%s) - start ))s (full log: test/fileserver-user-data.log)"

echo "--- second run (must be idempotent: rebuilt instance, same volume)"
docker exec -e AWS_REGION=eu-central-1 -e ARCHIVE_BUCKET=archive-test \
  -e ZONES="team-a team-b" -e ADMIN_USER=fsadmin \
  -e ADMIN_PASSWORD='Test-Admin_Pass1!' -e DATA_DEVICE="$DATA_DEVICE" \
  "$SRV" bash /fileserver-user-data.sh > fileserver-user-data-rerun.log 2>&1 \
  && echo "second run OK" || { echo "second run FAILED"; tail -20 fileserver-user-data-rerun.log; exit 1; }

docker exec -e DATA_DEVICE="$DATA_DEVICE" "$SRV" bash /fileserver-checks.sh
