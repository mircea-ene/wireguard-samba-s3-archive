# Admin passwords. Generated here, stored as SSM SecureString, read by the
# instances at boot through their IAM role (never written into user-data).
# Read them with:
#   aws ssm get-parameter --with-decryption --name <name> --query Parameter.Value --output text
# Note: like every Terraform-generated secret, they are also in the state file.

resource "random_password" "cockpit_admin" {
  length           = 24
  special          = true
  override_special = "-_!%*+="
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "random_password" "wg_easy_admin" {
  length           = 24
  special          = true
  override_special = "-_!%*+="
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "aws_ssm_parameter" "cockpit_admin_password" {
  name        = "/${var.project}/${var.env}/fileserver/admin-password"
  description = "Password of ${var.admin_username} on the file server (Cockpit login)."
  type        = "SecureString"
  value       = random_password.cockpit_admin.result
}

resource "aws_ssm_parameter" "wg_easy_admin_password" {
  name        = "/${var.project}/${var.env}/vpn/wg-easy-admin-password"
  description = "Password of the wg-easy web UI."
  type        = "SecureString"
  value       = random_password.wg_easy_admin.result
}
