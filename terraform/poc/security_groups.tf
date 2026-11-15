# VPN server: WireGuard open to the internet (devices roam), the wg-easy
# admin page only from the admin address. No SSH anywhere: Session Manager.
resource "aws_security_group" "vpn" {
  name        = "${local.name_prefix}-vpn"
  description = "WireGuard server"
  vpc_id      = aws_default_vpc.default.id

  tags = {
    Name = "${local.name_prefix}-vpn"
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpn_wireguard" {
  security_group_id = aws_security_group.vpn.id
  description       = "WireGuard from anywhere"
  ip_protocol       = "udp"
  from_port         = var.wg_port
  to_port           = var.wg_port
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "vpn_ui" {
  security_group_id = aws_security_group.vpn.id
  description       = "wg-easy admin UI from the admin address only"
  ip_protocol       = "tcp"
  from_port         = var.wg_ui_port
  to_port           = var.wg_ui_port
  cidr_ipv4         = var.admin_cidr
}

resource "aws_vpc_security_group_egress_rule" "vpn_all" {
  security_group_id = aws_security_group.vpn.id
  description       = "Updates, and forwarded VPN traffic to the file server"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# File server: nothing from the internet. Only traffic that came through the
# VPN server (WireGuard NATs device traffic to the VPN server's private IP).
resource "aws_security_group" "fileserver" {
  name        = "${local.name_prefix}-fileserver"
  description = "Samba file server, reachable only through the VPN"
  vpc_id      = aws_default_vpc.default.id

  tags = {
    Name = "${local.name_prefix}-fileserver"
  }
}

locals {
  fileserver_ports_from_vpn = {
    smb     = { port = 445, protocol = "tcp", description = "SMB file shares" }
    cockpit = { port = 9090, protocol = "tcp", description = "Cockpit admin" }
    iperf3  = { port = 5201, protocol = "tcp", description = "iperf3 network speed test (PoC only)" }
  }
}

resource "aws_vpc_security_group_ingress_rule" "fileserver_from_vpn" {
  for_each = local.fileserver_ports_from_vpn

  security_group_id            = aws_security_group.fileserver.id
  description                  = "${each.value.description} from VPN"
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = aws_security_group.vpn.id
}

resource "aws_vpc_security_group_ingress_rule" "fileserver_ping_from_vpn" {
  security_group_id            = aws_security_group.fileserver.id
  description                  = "Ping from VPN"
  ip_protocol                  = "icmp"
  from_port                    = -1
  to_port                      = -1
  referenced_security_group_id = aws_security_group.vpn.id
}

resource "aws_vpc_security_group_egress_rule" "fileserver_all" {
  security_group_id = aws_security_group.fileserver.id
  description       = "Updates and S3 (outbound only)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
