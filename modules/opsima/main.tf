locals {
  common_tags = merge(
    { owner = "opsima" },
    var.tags,
  )

  # AWS Organizations path prefixes used to scope what Opsima may touch:
  #   - accounts sitting directly at the org root (freshly created, not yet moved)
  #   - anything inside the Opsima OU this module owns
  org_path_root   = "${var.organization_id}/${var.organization_root_id}/"
  org_path_opsima = "${var.organization_id}/${var.organization_root_id}/${aws_organizations_organizational_unit.opsima.id}/*"
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "cur" {
  count = var.create_cur_bucket ? 1 : 0

  bucket = "opsima-cur-${var.customer_short_id}"
  tags   = local.common_tags

  # Mirrors the source CFN DeletionPolicy: RetainExceptOnCreate.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "cur" {
  count  = var.create_cur_bucket ? 1 : 0
  bucket = aws_s3_bucket.cur[0].id

  versioning_configuration {
    status = "Suspended"
  }
}

data "aws_iam_policy_document" "cur" {
  count = var.create_cur_bucket ? 1 : 0

  statement {
    sid       = "DenyInsecureTransportAll"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.cur[0].arn, "${aws_s3_bucket.cur[0].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "AllowBCMDataExportsServiceWriteObjects"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetBucketAcl", "s3:GetBucketPolicy"]
    resources = [aws_s3_bucket.cur[0].arn, "${aws_s3_bucket.cur[0].arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["bcm-data-exports.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "cur" {
  count  = var.create_cur_bucket ? 1 : 0
  bucket = aws_s3_bucket.cur[0].id
  policy = data.aws_iam_policy_document.cur[0].json
}

# The Opsima OU is the boundary the whole security model hangs off, so this
# module always owns it — it is not an input.
resource "aws_organizations_organizational_unit" "opsima" {
  name      = "opsima-${var.customer_short_id}"
  parent_id = var.organization_root_id
  tags      = local.common_tags
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [var.opsima_principal]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.external_id]
    }
  }
}

resource "aws_iam_role" "opsima_remote_access" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "opsima_remote_access" {
  statement {
    sid       = "AllowOpsimaCoreOperations"
    effect    = "Allow"
    resources = ["*"]
    actions = [
      "bcm-data-exports:CreateExport",
      "bcm-data-exports:TagResource",
      "bcm-data-exports:ListExports",
      "bcm-data-exports:GetExport",
      "ce:GetSavingsPlansCoverage",
      "ce:GetSavingsPlansUtilization",
      "ce:GetReservationCoverage",
      "ce:GetReservationUtilization",
      "ce:GetCostAndUsage",
      "ce:GetDimensionValues",
      "cur:PutReportDefinition",
      "cur:DescribeReportDefinitions",
      "cur:TagResource",
      "organizations:TagResource",
      "organizations:ListAccounts",
      "organizations:ListTagsForResource",
      "organizations:InviteAccountToOrganization",
      "organizations:DescribeCreateAccountStatus",
      "invoicing:CreateInvoiceUnit",
      "invoicing:GetInvoiceUnit",
      "invoicing:UpdateInvoiceUnit",
      "invoicing:TagResource",
    ]
  }

  statement {
    sid       = "AllowOrganizationCreateAccount"
    effect    = "Allow"
    actions   = ["organizations:CreateAccount"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/owner"
      values   = ["opsima"]
    }
  }

  # MoveAccount is the dangerous grant. The account being moved must currently
  # sit at the org root (freshly created, not yet placed) or already inside the
  # Opsima OU.
  statement {
    sid     = "AllowMoveAccountsAtRootOrInOpsimaOU"
    effect  = "Allow"
    actions = ["organizations:MoveAccount"]
    resources = [
      "arn:aws:organizations::${data.aws_caller_identity.current.account_id}:account/${var.organization_id}/*",
    ]

    condition {
      test     = "ForAnyValue:StringLike"
      variable = "aws:ResourceOrgPaths"
      values   = [local.org_path_root, local.org_path_opsima]
    }
  }

  statement {
    sid     = "AllowMoveAccountParents"
    effect  = "Allow"
    actions = ["organizations:MoveAccount"]
    resources = [
      "arn:aws:organizations::${data.aws_caller_identity.current.account_id}:root/${var.organization_id}/${var.organization_root_id}",
      "arn:aws:organizations::${data.aws_caller_identity.current.account_id}:ou/${var.organization_id}/${aws_organizations_organizational_unit.opsima.id}",
    ]
  }

  # Assume into the cross-account role only in accounts that live under the
  # Opsima OU — not any account in the org that happens to have a role by
  # this name.
  statement {
    sid       = "AllowAssumeRole"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::*:role/OpsimaOrganizationAccountAccessRole"]

    condition {
      test     = "ForAnyValue:StringLike"
      variable = "aws:ResourceOrgPaths"
      values   = [local.org_path_opsima]
    }
  }

  statement {
    sid    = "AllowCURBucketAccess"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::opsima-cur-${var.customer_short_id}",
      "arn:aws:s3:::opsima-cur-${var.customer_short_id}/*",
    ]
  }

  statement {
    sid       = "AllowOrganizationsAccountQuotaIncrease"
    effect    = "Allow"
    actions   = ["servicequotas:RequestServiceQuotaIncrease"]
    resources = ["arn:aws:servicequotas::${data.aws_caller_identity.current.account_id}:organizations/L-E619E033"]
  }
}

resource "aws_iam_role_policy" "opsima_remote_access" {
  name   = "OpsimaRemoteAccessRolePolicy"
  role   = aws_iam_role.opsima_remote_access.id
  policy = data.aws_iam_policy_document.opsima_remote_access.json
}
