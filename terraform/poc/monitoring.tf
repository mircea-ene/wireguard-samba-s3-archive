# Optional alerts by email. Off unless alarm_email is set.
#
#   - either instance down (EC2 status checks, no agent needed)
#   - data volume (/srv) almost full (CloudWatch agent, installed and
#     configured through Systems Manager, so turning monitoring on or off
#     does not replace the instance)
#   - S3 spend above a monthly budget
#
# AWS sends a confirmation email to alarm_email after the first apply; no
# alerts arrive until the link in it is clicked.

locals {
  monitoring_enabled = var.alarm_email != null
  alarm_actions      = local.monitoring_enabled ? [aws_sns_topic.alarms[0].arn] : []
}

resource "aws_sns_topic" "alarms" {
  count = local.monitoring_enabled ? 1 : 0

  name = "${local.name_prefix}-alarms"
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count = local.monitoring_enabled ? 1 : 0

  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ------------------------------------------------------------ instance down --

resource "aws_cloudwatch_metric_alarm" "instance_down" {
  for_each = local.monitoring_enabled ? {
    fileserver = aws_instance.fileserver.id
    vpn        = aws_instance.vpn.id
  } : {}

  alarm_name          = "${local.name_prefix}-${each.key}-down"
  alarm_description   = "The ${each.key} instance failed its status checks or stopped reporting."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  # A stopped instance sends no data at all: treat that as down too.
  treat_missing_data = "breaching"
  alarm_actions      = local.alarm_actions
  ok_actions         = local.alarm_actions
}

# ------------------------------------------------------- data volume usage --

resource "aws_iam_role_policy_attachment" "fileserver_cloudwatch_agent" {
  count = local.monitoring_enabled ? 1 : 0

  role       = aws_iam_role.fileserver.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# The managed policy above lets the agent read parameters named
# AmazonCloudWatch-*.
resource "aws_ssm_parameter" "cloudwatch_agent_config" {
  count = local.monitoring_enabled ? 1 : 0

  name = "AmazonCloudWatch-${local.name_prefix}-fileserver"
  type = "String"
  value = jsonencode({
    agent = {
      metrics_collection_interval = 300
      omit_hostname               = true
    }
    metrics = {
      namespace         = local.name_prefix
      append_dimensions = { InstanceId = "$${aws:InstanceId}" }
      metrics_collected = {
        disk = {
          measurement = ["used_percent"]
          resources   = ["/srv"]
          drop_device = true
        }
      }
    }
  })
}

resource "aws_ssm_association" "cloudwatch_agent_install" {
  count = local.monitoring_enabled ? 1 : 0

  association_name = "${local.name_prefix}-cloudwatch-agent-install"
  name             = "AWS-ConfigureAWSPackage"
  parameters = {
    action = "Install"
    name   = "AmazonCloudWatchAgent"
  }

  targets {
    key    = "InstanceIds"
    values = [aws_instance.fileserver.id]
  }

  # Lets the configure step below run only after the agent is installed.
  wait_for_success_timeout_seconds = 900

  depends_on = [aws_iam_role_policy_attachment.fileserver_cloudwatch_agent]
}

resource "aws_ssm_association" "cloudwatch_agent_configure" {
  count = local.monitoring_enabled ? 1 : 0

  association_name = "${local.name_prefix}-cloudwatch-agent-configure"
  name             = "AmazonCloudWatch-ManageAgent"
  parameters = {
    action                        = "configure"
    mode                          = "ec2"
    optionalConfigurationSource   = "ssm"
    optionalConfigurationLocation = aws_ssm_parameter.cloudwatch_agent_config[0].name
    optionalRestart               = "yes"
  }

  targets {
    key    = "InstanceIds"
    values = [aws_instance.fileserver.id]
  }

  depends_on = [aws_ssm_association.cloudwatch_agent_install]
}

resource "aws_cloudwatch_metric_alarm" "data_disk_full" {
  count = local.monitoring_enabled ? 1 : 0

  alarm_name        = "${local.name_prefix}-fileserver-data-disk-full"
  alarm_description = "The file server data volume (/srv) is over ${var.disk_alarm_percent}% full."
  namespace         = local.name_prefix
  metric_name       = "disk_used_percent"
  dimensions = {
    InstanceId = aws_instance.fileserver.id
    path       = "/srv"
    fstype     = "xfs"
  }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.disk_alarm_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# ---------------------------------------------------------------- S3 spend --

# Covers all S3 spend in the account, not only this bucket (filtering by
# tag would first need cost allocation tags activated in Billing).
resource "aws_budgets_budget" "s3" {
  count = local.monitoring_enabled ? 1 : 0

  name         = "${local.name_prefix}-s3"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.s3_monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "Service"
    values = ["Amazon Simple Storage Service"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alarm_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alarm_email]
  }
}
