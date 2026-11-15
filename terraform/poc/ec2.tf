# Ubuntu 24.04 images published by Canonical.
data "aws_ssm_parameter" "ubuntu_amd64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_ssm_parameter" "ubuntu_arm64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

# Free gateway endpoint: archive reads go to S3 over the AWS network.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_default_vpc.default.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_default_vpc.default.default_route_table_id]

  tags = {
    Name = "${local.name_prefix}-s3"
  }
}

# ---------------------------------------------------------------------------
# VPN server (WireGuard + wg-easy)
# ---------------------------------------------------------------------------

# Allocated separately so its address can go into the instance's user-data
# (devices' configs point at it) without a dependency cycle.
resource "aws_eip" "vpn" {
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-vpn"
  }
}

resource "aws_instance" "vpn" {
  ami                    = data.aws_ssm_parameter.ubuntu_arm64.value
  instance_type          = var.vpn_instance_type
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.vpn.id]
  iam_instance_profile   = aws_iam_instance_profile.vpn.name

  user_data_replace_on_change = true
  user_data = join("\n", [
    "#!/bin/bash",
    "export AWS_REGION='${var.aws_region}'",
    "export WG_HOST='${aws_eip.vpn.public_ip}'",
    "export WG_PORT='${var.wg_port}'",
    "export WG_UI_PORT='${var.wg_ui_port}'",
    "export WG_CLIENT_CIDR='${var.wg_client_cidr}'",
    # Split tunnel: devices send only VPC traffic through the VPN.
    "export WG_ALLOWED_IPS='${aws_default_vpc.default.cidr_block}'",
    "export WG_EASY_IMAGE='${var.wg_easy_image}'",
    "export WG_ADMIN_USER='${var.wg_easy_admin_username}'",
    "export WG_ADMIN_PASSWORD_PARAM='${aws_ssm_parameter.wg_easy_admin_password.name}'",
    file("${path.module}/templates/vpn-user-data.sh"),
  ])

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 10
    encrypted   = true
  }

  lifecycle {
    # A new Ubuntu image should not replace a running PoC instance.
    ignore_changes = [ami]
  }

  tags = {
    Name = "${local.name_prefix}-vpn"
  }
}

resource "aws_eip_association" "vpn" {
  instance_id   = aws_instance.vpn.id
  allocation_id = aws_eip.vpn.id
}

# ---------------------------------------------------------------------------
# File server (Samba + rclone archive mounts + Cockpit)
# ---------------------------------------------------------------------------

# Active project data. Separate from the instance, so the instance can be
# rebuilt (e.g. after a user-data change) without losing files.
resource "aws_ebs_volume" "data" {
  availability_zone = local.az
  type              = "gp3"
  size              = var.data_volume_size_gb
  encrypted         = true

  tags = {
    Name = "${local.name_prefix}-fileserver-data"
  }
}

resource "aws_instance" "fileserver" {
  ami                    = data.aws_ssm_parameter.ubuntu_amd64.value
  instance_type          = var.fileserver_instance_type
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.fileserver.id]
  iam_instance_profile   = aws_iam_instance_profile.fileserver.name

  # Public address for outbound updates only (no NAT gateway); the security
  # group allows nothing in from the internet.
  associate_public_ip_address = true

  user_data_replace_on_change = true
  user_data = join("\n", [
    "#!/bin/bash",
    "export AWS_REGION='${var.aws_region}'",
    "export ARCHIVE_BUCKET='${aws_s3_bucket.archive.bucket}'",
    "export ZONES='${join(" ", var.zones)}'",
    "export DATA_VOLUME_ID='${aws_ebs_volume.data.id}'",
    "export RCLONE_CACHE_MAX_SIZE='${var.rclone_cache_max_size}'",
    "export ADMIN_USER='${var.admin_username}'",
    "export ADMIN_PASSWORD_PARAM='${aws_ssm_parameter.cockpit_admin_password.name}'",
    "export COCKPIT_IDENTITIES_DEB_URL='${var.cockpit_identities_deb_url}'",
    file("${path.module}/templates/fileserver-user-data.sh"),
  ])

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = "${local.name_prefix}-fileserver"
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.fileserver.id
}
