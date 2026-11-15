# Local Docker PoC: file server + archive

One container that behaves like the real server: Samba shares for active
projects and write-once uploads, and an S3 bucket mounted read-only as the archive.

## Run with a real S3 test bucket (the meaningful test)

1. Create a bucket in eu-central-1 with folders `team-a/` and `team-b/`,
   and upload some real files (use storage class Glacier Instant Retrieval).
2. Copy `env.aws.example` to `env.aws` and fill it in (bucket name and a read-only access key).
3. `docker compose --env-file env.aws up --build`

## Run fully offline (fake S3)

Put test files in `fake-s3/archive-test/team-a/` and `.../team-b/`, then:

    docker compose --env-file env.local --profile local up --build

## Test

    docker compose exec server /test.sh

Test users: `alice` (team-a), `bob` (team-b), `carol` (both). Password `test1234`.

Connect from the host on port 1445:
- Linux:  `smbclient //localhost/Projects -p 1445 -U alice`
- macOS:  Finder > Go > Connect to Server > `smb://localhost:1445/Projects`
- Windows: Explorer cannot use a non-standard port on the same machine;
  use the test script, or run the container on another machine / a VM.

## Shares

| Share    | Behaviour                                                        |
|----------|------------------------------------------------------------------|
| Projects | Read-write. Each project folder is open only to its group.       |
| Uploads  | Upload only. Uploaded files cannot be changed, renamed, deleted. |
| Archive  | The S3 bucket, read-only. Each zone is visible only to its group.|

Change users, groups and zones with the `USERS` and `ZONES` variables
(see the top of `entrypoint.sh`).

## Not covered here

VPN (WireGuard), the admin web pages, backups and audit logging are tested
by `terraform/poc/test/` and on EC2, not in this container.
