data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# File server: Session Manager, read-only archive bucket, its own password
# ---------------------------------------------------------------------------

resource "aws_iam_role" "fileserver" {
  name               = "${local.name_prefix}-fileserver"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "fileserver_ssm" {
  role       = aws_iam_role.fileserver.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "fileserver" {
  statement {
    sid       = "ListArchive"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.archive.arn]
  }

  statement {
    sid       = "ReadArchive"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.archive.arn}/*"]
  }

  statement {
    sid       = "ReadOwnSecrets"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.cockpit_admin_password.arn]
  }
}

resource "aws_iam_role_policy" "fileserver" {
  name   = "fileserver"
  role   = aws_iam_role.fileserver.id
  policy = data.aws_iam_policy_document.fileserver.json
}

resource "aws_iam_instance_profile" "fileserver" {
  name = "${local.name_prefix}-fileserver"
  role = aws_iam_role.fileserver.name
}

# ---------------------------------------------------------------------------
# VPN server: Session Manager and its own password only
# ---------------------------------------------------------------------------

resource "aws_iam_role" "vpn" {
  name               = "${local.name_prefix}-vpn"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "vpn_ssm" {
  role       = aws_iam_role.vpn.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "vpn" {
  statement {
    sid       = "ReadOwnSecrets"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.wg_easy_admin_password.arn]
  }
}

resource "aws_iam_role_policy" "vpn" {
  name   = "vpn"
  role   = aws_iam_role.vpn.id
  policy = data.aws_iam_policy_document.vpn.json
}

resource "aws_iam_instance_profile" "vpn" {
  name = "${local.name_prefix}-vpn"
  role = aws_iam_role.vpn.name
}
