variable "aws_region" {
  type        = string
  description = "AWS Region to deploy the infrastructure into."
}

variable "env" {
  type        = string
  description = "Environment name used in resource names and tags (e.g. dev)."
}

variable "profile" {
  type        = string
  description = "AWS CLI profile. Leave null to use the default credential chain (env vars, SSO, instance role)."
  default     = null
}

# ---------------------------------------------------------------------------
# File server + VPN proof of concept
# ---------------------------------------------------------------------------

variable "project" {
  type        = string
  description = "Short project name used in resource names."
  default     = "smb-archive"
}

variable "admin_cidr" {
  type        = string
  description = "The only address allowed to reach the admin endpoints directly (wg-easy UI). WireGuard itself is open to everyone."
  # No default on purpose: set it to your own public IP, e.g. "203.0.113.10/32".

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be a valid CIDR and must not be 0.0.0.0/0."
  }
}

variable "fileserver_instance_type" {
  type        = string
  description = "Instance type of the Samba file server (x86_64)."
  default     = "t3.medium"
}

variable "vpn_instance_type" {
  type        = string
  description = "Instance type of the WireGuard server (arm64 / Graviton)."
  default     = "t4g.micro"
}

variable "data_volume_size_gb" {
  type        = number
  description = "Size of the encrypted gp3 volume that holds the active project files (300 GB in production)."
  default     = 30
}

variable "zones" {
  type        = list(string)
  description = "Access zones. Each one becomes a Linux group, a folder in Projects and Uploads, and a read-only mount of the bucket prefix with the same name in Archive."
  default     = ["team-a", "team-b"]
}

variable "rclone_cache_max_size" {
  type        = string
  description = "Maximum size of the local read cache for the archive mounts, per zone."
  default     = "5G"
}

variable "admin_username" {
  type        = string
  description = "Linux user on the file server used to log in to Cockpit (has sudo)."
  default     = "fsadmin"
}

variable "wg_easy_image" {
  type        = string
  description = "wg-easy container image (pinned)."
  default     = "ghcr.io/wg-easy/wg-easy:15.5.0"
}

variable "wg_easy_admin_username" {
  type        = string
  description = "Username for the wg-easy web UI."
  default     = "admin"
}

variable "wg_port" {
  type        = number
  description = "WireGuard UDP port."
  default     = 51820
}

variable "wg_ui_port" {
  type        = number
  description = "wg-easy web UI TCP port."
  default     = 51821
}

variable "wg_client_cidr" {
  type        = string
  description = "Address range handed out to VPN devices."
  default     = "10.8.0.0/24"
}

variable "cockpit_identities_deb_url" {
  type        = string
  description = "45Drives Cockpit Identities plugin package. There is no Ubuntu 24.04 build; the jammy one is architecture independent."
  default     = "https://github.com/45Drives/cockpit-identities/releases/download/v0.1.14-1/cockpit-identities_0.1.14-1jammy_all.deb"
}
