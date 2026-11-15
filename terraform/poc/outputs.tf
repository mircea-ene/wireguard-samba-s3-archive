output "archive_bucket" {
  description = "Archive bucket. Upload test data into <zone>/ prefixes with --storage-class GLACIER_IR."
  value       = aws_s3_bucket.archive.bucket
}

output "vpn_public_ip" {
  description = "WireGuard endpoint."
  value       = aws_eip.vpn.public_ip
}

output "wg_easy_url" {
  description = "wg-easy admin page (reachable only from admin_cidr)."
  value       = "http://${aws_eip.vpn.public_ip}:${var.wg_ui_port}"
}

output "fileserver_private_ip" {
  description = "Map network drives to \\\\<this>\\Projects etc. (through the VPN)."
  value       = aws_instance.fileserver.private_ip
}

output "cockpit_url" {
  description = "Cockpit admin (through the VPN). Self-signed certificate."
  value       = "https://${aws_instance.fileserver.private_ip}:9090"
}

output "fileserver_instance_id" {
  value = aws_instance.fileserver.id
}

output "vpn_instance_id" {
  value = aws_instance.vpn.id
}

output "get_passwords" {
  description = "Commands that print the admin passwords."
  value = {
    cockpit = "aws ssm get-parameter ${local.profile_flag}--region ${var.aws_region} --with-decryption --name ${aws_ssm_parameter.cockpit_admin_password.name} --query Parameter.Value --output text"
    wg_easy = "aws ssm get-parameter ${local.profile_flag}--region ${var.aws_region} --with-decryption --name ${aws_ssm_parameter.wg_easy_admin_password.name} --query Parameter.Value --output text"
  }
}

output "session_manager" {
  description = "Shell on the instances without SSH."
  value = {
    fileserver = "aws ssm start-session ${local.profile_flag}--region ${var.aws_region} --target ${aws_instance.fileserver.id}"
    vpn        = "aws ssm start-session ${local.profile_flag}--region ${var.aws_region} --target ${aws_instance.vpn.id}"
  }
}
