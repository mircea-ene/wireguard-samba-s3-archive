#!/bin/bash
set -euo pipefail

# ---- test users and groups (PoC only; passwords come from the env file) ----
# ZONES: "folder:group" pairs. Each one is a project folder, a site-log folder
# and an archive prefix in the bucket, all restricted to that group.
ZONES="${ZONES:-team-a:team-a team-b:team-b}"
# USERS: "name:password:group1,group2"
USERS="${USERS:-alice:test1234:team-a bob:test1234:team-b carol:test1234:team-a,team-b}"
BUCKET="${ARCHIVE_BUCKET:?set ARCHIVE_BUCKET}"

groupadd -f staff
id uploads-owner >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin uploads-owner

mkdir -p /srv/projects /srv/uploads /srv/archive
chmod 755 /srv/projects /srv/uploads /srv/archive

for z in $ZONES; do
  folder="${z%%:*}"; group="${z##*:}"
  groupadd -f "$group"
  mkdir -p "/srv/projects/$folder" "/srv/uploads/$folder" "/srv/archive/$folder"
  chown root:"$group" "/srv/projects/$folder";   chmod 2770 "/srv/projects/$folder"
  # sticky + setgid, owned by 'uploads-owner': members can add files, not change them
  chown uploads-owner:"$group" "/srv/uploads/$folder"; chmod 3770 "/srv/uploads/$folder"
done

for u in $USERS; do
  IFS=: read -r name pass groups <<<"$u"
  id "$name" >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin -G "staff,$groups" "$name"
  printf '%s\n%s\n' "$pass" "$pass" | smbpasswd -s -a "$name" >/dev/null
done

# ---- archive: one read-only mount per zone, readable only by its group ----
for z in $ZONES; do
  folder="${z%%:*}"; group="${z##*:}"
  gid="$(getent group "$group" | cut -d: -f3)"
  rclone mount "archive:${BUCKET}/${folder}" "/srv/archive/${folder}" \
    --read-only --allow-other --use-server-modtime \
    --uid 0 --gid "$gid" --dir-perms 0750 --file-perms 0640 \
    --vfs-cache-mode full --vfs-cache-max-size "${CACHE_MAX_SIZE:-5G}" \
    --dir-cache-time "${DIR_CACHE_TIME:-10m}" \
    --daemon --log-file /var/log/rclone-"$folder".log
done

echo "PoC ready: shares Projects, Uploads, Archive on port 445"
exec smbd --foreground --no-process-group --debug-stdout
