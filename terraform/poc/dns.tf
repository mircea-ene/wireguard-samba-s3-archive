# Private DNS name for the file server, e.g. files.office.internal, so mapped
# drives keep working when the instance is replaced (its private IP changes,
# Terraform updates the record).
#
# VPN devices get the VPC DNS server (VPC CIDR + 2) as their DNS server. It
# is inside the tunnel's AllowedIPs, so all lookups go through the VPN while
# it is on; other internet traffic still goes out directly. Set
# private_domain = null to turn this off (devices then use 1.1.1.1).

locals {
  private_dns_enabled = var.private_domain != null
  vpc_dns_server      = cidrhost(aws_default_vpc.default.cidr_block, 2)
  vpn_dns             = local.private_dns_enabled ? local.vpc_dns_server : "1.1.1.1"
  fileserver_address  = local.private_dns_enabled ? aws_route53_record.fileserver[0].fqdn : aws_instance.fileserver.private_ip
}

resource "aws_route53_zone" "private" {
  count = local.private_dns_enabled ? 1 : 0

  name    = var.private_domain
  comment = "Private names for ${local.name_prefix}, resolvable inside the VPC and over the VPN"

  vpc {
    vpc_id = aws_default_vpc.default.id
  }
}

resource "aws_route53_record" "fileserver" {
  count = local.private_dns_enabled ? 1 : 0

  zone_id = aws_route53_zone.private[0].zone_id
  name    = "${var.fileserver_hostname}.${var.private_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.fileserver.private_ip]
}
