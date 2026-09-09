locals {
  # Mirrors the CFN Conditions block:
  #   ShouldCreateCURBucket
  #   ShouldCreateOpsimaOrganizationalUnit
  should_create_ou = var.opsima_organizational_unit_id == "" && var.create_opsima_organizational_unit

  # Effective OU id: the one we created, the one that was passed in, or empty.
  effective_ou_id = local.should_create_ou ? aws_organizations_organizational_unit.opsima[0].id : var.opsima_organizational_unit_id

  common_tags = merge(
    { owner = "opsima" },
    var.tags,
  )
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

resource "aws_organizations_organizational_unit" "opsima" {
  count = local.should_create_ou ? 1 : 0

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

  statement {
    sid     = "AllowOrganizationMoveAccount"
    effect  = "Allow"
    actions = ["organizations:MoveAccount"]
    resources = compact([
      "arn:aws:organizations::${data.aws_caller_identity.current.account_id}:account/${var.organization_id}/*",
      "arn:aws:organizations::${data.aws_caller_identity.current.account_id}:root/*",
      local.effective_ou_id == "" ? "" : "arn:aws:organizations::${data.aws_caller_identity.current.account_id}:ou/${var.organization_id}/${local.effective_ou_id}",
    ])
  }

  statement {
    sid       = "AllowAssumeRole"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::*:role/OpsimaOrganizationAccountAccessRole"]
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

########################################
# "Handshake" notification back to Opsima
########################################
# The source CFN template ends with a Custom::OpsimaHandshake resource whose
# ServiceToken is an SNS topic owned by Opsima: CloudFormation publishes a
# message to that topic (in the custom-resource protocol Opsima's Lambda
# expects) so their backend picks up the new role.
#
# Terraform has no native "publish this custom-resource message" primitive, so
# instead of reverse-engineering the payload we run the original handshake as a
# one-resource nested CloudFormation stack. CloudFormation does the publish,
# the Create/Update/Delete lifecycle works, and there's no `aws` CLI or extra
# provider needed on the apply host.
#
# The apply credentials need cloudformation:CreateStack / UpdateStack /
# DeleteStack / DescribeStacks (and Opsima's SNS topic policy must allow
# CloudFormation to publish, which it already did for the CFN template).
#
# Set enable_opsima_handshake = false to skip this and onboard from Opsima's UI.

resource "aws_cloudformation_stack" "opsima_handshake" {
  count = var.enable_opsima_handshake ? 1 : 0

  name = "opsima-remote-access-handshake"

  parameters = {
    ServiceToken               = var.opsima_handshake_sns_topic_arn
    CloudFormationStackVersion = var.cloudformation_stack_version
    RoleArn                    = aws_iam_role.opsima_remote_access.arn
    ExternalID                 = var.external_id
    OrganizationId             = var.organization_id
    OrganizationRootId         = var.organization_root_id
    OpsimaOrganizationalUnitId = local.effective_ou_id
    OpsimaInvoiceUnitArn       = var.opsima_invoice_unit_arn
  }

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Opsima remote access handshake (managed by Terraform)"

    Parameters = {
      ServiceToken               = { Type = "String" }
      CloudFormationStackVersion = { Type = "String" }
      RoleArn                    = { Type = "String" }
      ExternalID                 = { Type = "String", NoEcho = true }
      OrganizationId             = { Type = "String" }
      OrganizationRootId         = { Type = "String" }
      OpsimaOrganizationalUnitId = { Type = "String", Default = "" }
      OpsimaInvoiceUnitArn       = { Type = "String", Default = "" }
    }

    Resources = {
      OpsimaHandshake = {
        Type = "Custom::OpsimaHandshake"
        Properties = {
          ServiceToken               = { Ref = "ServiceToken" }
          CloudFormationStackVersion = { Ref = "CloudFormationStackVersion" }
          CloudFormationStackType    = "full"
          RoleArn                    = { Ref = "RoleArn" }
          ExternalID                 = { Ref = "ExternalID" }
          OrganizationId             = { Ref = "OrganizationId" }
          OrganizationRootId         = { Ref = "OrganizationRootId" }
          OpsimaOrganizationalUnitId = { Ref = "OpsimaOrganizationalUnitId" }
          OpsimaInvoiceUnitArn       = { Ref = "OpsimaInvoiceUnitArn" }
        }
      }
    }
  })

  depends_on = [aws_iam_role_policy.opsima_remote_access]
}
