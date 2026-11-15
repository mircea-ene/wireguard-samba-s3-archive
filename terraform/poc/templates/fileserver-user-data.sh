#!/bin/bash
# File server setup: Samba shares, S3 archive mounts (rclone), Cockpit admin.
#
# Terraform prepends `export` lines for the variables below. The script is
# plain bash (no Terraform template syntax) so it can be tested in Docker:
# see templates/test/run-fileserver-test.sh.
#
# Required:  AWS_REGION ARCHIVE_BUCKET ZONES ADMIN_USER
#            ADMIN_PASSWORD_PARAM (or ADMIN_PASSWORD)
#            DATA_VOLUME_ID       (or DATA_DEVICE=/dev/xxx, or DATA_DEVICE=none)
# Optional:  RCLONE_CACHE_MAX_SIZE COCKPIT_IDENTITIES_DEB_URL
#
# Test seams (never set on EC2):
#   ADMIN_PASSWORD  skip the SSM lookup
#   DATA_DEVICE     skip the EBS lookup ("none" = use the root disk)
#   an existing /etc/rclone/rclone.conf is kept (lets tests point at a fake S3)
set -euo pipefail
exec > >(tee -a /var/log/fileserver-setup.log) 2>&1
echo "=== file server setup started $(date -Is)"

: "${AWS_REGION:?}" "${ARCHIVE_BUCKET:?}" "${ZONES:?}" "${ADMIN_USER:?}"
RCLONE_CACHE_MAX_SIZE="${RCLONE_CACHE_MAX_SIZE:-5G}"
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -q -o DPkg::Lock::Timeout=600"

case "$(uname -m)" in
  x86_64)  DEB_ARCH=amd64 ;;
  aarch64) DEB_ARCH=arm64 ;;
  *) echo "unsupported architecture $(uname -m)"; exit 1 ;;
esac

# ---------------------------------------------------------------- packages --
$APT update
$APT install --no-install-recommends \
  samba smbclient fuse3 xfsprogs acl curl unzip ca-certificates iperf3
# Cockpit from backports: much newer than 24.04's 314, and includes the
# "Files" page where the admin can change owners, groups and permissions.
$APT install -t noble-backports cockpit cockpit-files
# 45Drives Identities: users, groups and Samba passwords from the browser.
if [ -n "${COCKPIT_IDENTITIES_DEB_URL:-}" ]; then
  curl -fsSL -o /tmp/cockpit-identities.deb "$COCKPIT_IDENTITIES_DEB_URL"
  $APT install /tmp/cockpit-identities.deb
fi
# Current rclone (Ubuntu ships 1.60, which lacks needed fixes).
curl -fsSL -o /tmp/rclone.deb "https://downloads.rclone.org/rclone-current-linux-${DEB_ARCH}.deb"
dpkg -i /tmp/rclone.deb
rclone version | head -1

# --------------------------------------------------------- admin password --
if [ -z "${ADMIN_PASSWORD:-}" ]; then
  if ! command -v aws >/dev/null; then
    curl -fsSL -o /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip"
    unzip -q -o /tmp/awscliv2.zip -d /tmp && /tmp/aws/install --update
  fi
  ADMIN_PASSWORD="$(aws ssm get-parameter --region "$AWS_REGION" --name "${ADMIN_PASSWORD_PARAM:?}" \
    --with-decryption --query Parameter.Value --output text)"
fi

# ------------------------------------------------- data volume on /srv --
if [ "${DATA_DEVICE:-}" != "none" ]; then
  dev="${DATA_DEVICE:-}"
  if [ -z "$dev" ]; then
    # Nitro instances expose EBS as NVMe; the volume ID (without the dash)
    # is the serial number. Terraform attaches the volume after boot starts.
    link="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${DATA_VOLUME_ID:?}"
    link="${link/vol-/vol}"
    for _ in $(seq 1 120); do [ -e "$link" ] && break; sleep 5; done
    [ -e "$link" ] || { echo "data volume $DATA_VOLUME_ID never appeared"; exit 1; }
    dev="$(readlink -f "$link")"
  fi
  # Format only if empty: a rebuilt instance keeps the existing files.
  blkid "$dev" >/dev/null 2>&1 || mkfs.xfs -L srvdata "$dev"
  uuid="$(blkid -s UUID -o value "$dev")"
  grep -q "$uuid" /etc/fstab || \
    echo "UUID=$uuid /srv xfs defaults,nofail,x-systemd.device-timeout=60s 0 2" >> /etc/fstab
  systemctl daemon-reload
  mkdir -p /srv
  mountpoint -q /srv || mount /srv
fi

# ------------------------------------------------------------ base layout --
groupadd -f staff
id uploads-owner >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin uploads-owner
mkdir -p /srv/projects /srv/uploads /srv/archive /srv/.rclone-cache /var/log/rclone
chmod 755 /srv/projects /srv/uploads /srv/archive
chmod 700 /srv/.rclone-cache

if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
fi
echo "$ADMIN_USER:$ADMIN_PASSWORD" | chpasswd
unset ADMIN_PASSWORD

# ------------------------------------------------------------------ rclone --
mkdir -p /etc/rclone
if ! grep -q '^\[archive\]' /etc/rclone/rclone.conf 2>/dev/null; then
  # env_auth: credentials come from the instance role, no keys on disk.
  cat > /etc/rclone/rclone.conf <<EOF
[archive]
type = s3
provider = AWS
env_auth = true
region = $AWS_REGION
location_constraint = $AWS_REGION
no_check_bucket = true
EOF
fi
chmod 600 /etc/rclone/rclone.conf

cat > /etc/default/fileserver-archive <<EOF
ARCHIVE_BUCKET=$ARCHIVE_BUCKET
RCLONE_CACHE_MAX_SIZE=$RCLONE_CACHE_MAX_SIZE
EOF

cat > /usr/local/sbin/fileserver-mount-zone <<'EOF'
#!/bin/bash
# Mounts one archive zone (bucket prefix) read-only, readable by its group.
# Started by rclone-archive@<zone>.service.
set -euo pipefail
. /etc/default/fileserver-archive
zone="$1"
gid="$(getent group "$zone" | cut -d: -f3)"
mkdir -p "/srv/archive/$zone"
exec /usr/bin/rclone mount "archive:${ARCHIVE_BUCKET}/${zone}" "/srv/archive/${zone}" \
  --config /etc/rclone/rclone.conf \
  --read-only --allow-other --use-server-modtime \
  --uid 0 --gid "$gid" --dir-perms 0750 --file-perms 0640 \
  --vfs-cache-mode full --vfs-cache-max-size "$RCLONE_CACHE_MAX_SIZE" \
  --cache-dir "/srv/.rclone-cache/$zone" \
  --dir-cache-time 10m \
  --log-file "/var/log/rclone/${zone}.log" --log-level INFO
EOF
chmod 755 /usr/local/sbin/fileserver-mount-zone

cat > /etc/systemd/system/rclone-archive@.service <<'EOF'
[Unit]
Description=Archive zone %i (S3, read-only)
After=network-online.target
Wants=network-online.target
RequiresMountsFor=/srv

[Service]
Type=notify
ExecStart=/usr/local/sbin/fileserver-mount-zone %i
ExecStop=/bin/fusermount3 -uz /srv/archive/%i
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# --------------------------------------------------------- add-zone helper --
cat > /usr/local/sbin/fileserver-add-zone <<'EOF'
#!/bin/bash
# Creates an access zone: a group, a read-write folder in Projects, an
# upload-only folder in Uploads and a read-only archive mount in Archive.
# Usage: sudo fileserver-add-zone <zone-name>
# Then add users to the group (Cockpit > Identities) and to "staff".
set -euo pipefail
zone="${1:?usage: fileserver-add-zone <zone-name>}"
[[ "$zone" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || { echo "zone must be lowercase letters, digits, dashes"; exit 1; }
groupadd -f "$zone"
mkdir -p "/srv/projects/$zone" "/srv/uploads/$zone" "/srv/archive/$zone"
chown root:"$zone" "/srv/projects/$zone";   chmod 2770 "/srv/projects/$zone"
# archive mountpoint: same access as the mount, so it stays closed if the mount is down
if ! mountpoint -q "/srv/archive/$zone"; then
  chown root:"$zone" "/srv/archive/$zone"; chmod 0750 "/srv/archive/$zone"
fi
# sticky + setgid, owned by 'uploads-owner': members can add files, not change them
chown uploads-owner:"$zone" "/srv/uploads/$zone"; chmod 3770 "/srv/uploads/$zone"
systemctl enable --now "rclone-archive@${zone}.service"
echo "zone $zone ready"
EOF
chmod 755 /usr/local/sbin/fileserver-add-zone

# ------------------------------------------------------------------- samba --
cat > /etc/samba/smb.conf <<'EOF'
[global]
   server role = standalone server
   workgroup = WORKGROUP
   map to guest = never
   server min protocol = SMB3
   smb encrypt = required
   disable netbios = yes
   smb ports = 445
   load printers = no
   printing = bsd
   log file = /var/log/samba/log.%m
   max log size = 10000
   log level = 1
   # users only see shares and folders they are allowed to open
   access based share enum = yes
   hide unreadable = yes

# Active projects: read-write, one group per project folder
[Projects]
   path = /srv/projects
   valid users = @staff
   read only = no
   inherit permissions = yes
   force create mode = 0660
   force directory mode = 2770

# Uploads: write-once drop folders. Upload allowed, changing or deleting afterwards is not.
# Uploaded files become owned by the folder owner and read-only.
[Uploads]
   path = /srv/uploads
   valid users = @staff
   read only = no
   inherit owner = yes
   create mask = 0440
   force create mode = 0440
   directory mask = 0000
   force directory mode = 3770

# Archive: the S3 bucket, read-only, one mount per access zone
[Archive]
   path = /srv/archive
   valid users = @staff
   read only = yes
EOF
testparm -s /etc/samba/smb.conf >/dev/null

# ---------------------------------------------------------- iperf3 (PoC) --
cat > /etc/systemd/system/iperf3-poc.service <<'EOF'
[Unit]
Description=iperf3 server for network speed tests (PoC)
After=network-online.target

[Service]
ExecStart=/usr/bin/iperf3 --server
Restart=on-failure
DynamicUser=yes

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------- services --
systemctl daemon-reload
for z in $ZONES; do
  /usr/local/sbin/fileserver-add-zone "$z"
done
systemctl disable --now nmbd 2>/dev/null || true
systemctl enable smbd
systemctl restart smbd
systemctl enable --now cockpit.socket iperf3-poc.service

touch /var/lib/fileserver-setup.done
echo "=== file server setup finished $(date -Is)"
