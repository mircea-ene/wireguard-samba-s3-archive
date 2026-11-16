# Optional daily snapshots of the file server data volume (Data Lifecycle
# Manager). Off unless backup_retention_days is set.
#
# Turning backups off again stops new snapshots; existing ones are kept
# (and billed) until deleted by hand.

locals {
  backups_enabled = var.backup_retention_days != null
  # Tag that DLM uses to find the volume. Always set on the volume, harmless
  # when backups are off.
  backup_tag = { Snapshot = "${local.name_prefix}-data" }
}

data "aws_iam_policy_document" "dlm_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  count = local.backups_enabled ? 1 : 0

  name               = "${local.name_prefix}-dlm"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  count = local.backups_enabled ? 1 : 0

  role       = aws_iam_role.dlm[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "data" {
  count = local.backups_enabled ? 1 : 0

  description        = "Daily snapshots of the file server data volume"
  execution_role_arn = aws_iam_role.dlm[0].arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = local.backup_tag

    schedule {
      name      = "daily"
      copy_tags = true

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["02:00"] # UTC, outside office hours in Europe
      }

      retain_rule {
        count = var.backup_retention_days
      }
    }
  }

  depends_on = [aws_iam_role_policy_attachment.dlm]
}
