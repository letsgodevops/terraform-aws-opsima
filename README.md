# terraform-aws-opsima-remote-access

Terraform re-implementation of Opsima's "full access" CloudFormation onboarding
stack (`opsima-cloud_formation-full_access.yaml`), packaged as a reusable
module so it can be dropped into multiple repos instead of copy-pasting a
CloudFormation template.

It creates:

- An optional S3 bucket for Cost & Usage Reports (`opsima-cur-<customer_short_id>`)
  with a bucket policy that denies insecure transport and allows the
  `bcm-data-exports.amazonaws.com` service to write reports.
- An optional AWS Organizations Organizational Unit for Opsima-managed
  accounts.
- The `OpsimaRemoteAccessRole` IAM role (assumable only by Opsima's account,
  gated by an external ID) and its inline policy.
- The CloudFormation "handshake" custom resource that tells Opsima the setup
  is done, run as a one-resource nested CloudFormation stack.

## Usage

Apply this module from your AWS Organization's **management account**, same as
the original CloudFormation stack — `organizations:CreateAccount`,
`MoveAccount`, and the OU resource all require that.

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

module "opsima_remote_access" {
  source = "git::https://github.com/<you>/terraform-aws-opsima-remote-access.git?ref=v1.0.0"

  # Values Opsima gave you when you started the "connect AWS account" flow.
  external_id       = var.opsima_external_id
  opsima_principal  = var.opsima_principal
  customer_short_id = var.opsima_customer_short_id

  # From your AWS Organization (or `data "aws_organizations_organization"`).
  organization_id      = var.organization_id
  organization_root_id = var.organization_root_id

  # Leave at defaults unless Opsima told you otherwise.
  create_cur_bucket                = true
  create_opsima_organizational_unit = true
  opsima_organizational_unit_id     = ""
  opsima_invoice_unit_arn           = ""

  tags = {
    environment = "shared"
    managed_by  = "terraform"
  }
}

variable "opsima_external_id" {
  type      = string
  sensitive = true
}
variable "opsima_principal" {
  type      = string
  sensitive = true
}
variable "opsima_customer_short_id" {
  type      = string
  sensitive = true
}
variable "organization_id" { type = string }
variable "organization_root_id" { type = string }

output "opsima_role_arn" {
  value = module.opsima_remote_access.role_arn
}
```

## Inputs

The first nine come from Opsima or your Organization and map 1:1 to the
CloudFormation parameters — leave them as Opsima instructs (they're all marked
`(DO NOT CHANGE)` in `variables.tf`, and most have a `validation` block that
rejects a malformed value). The last five are module-only conveniences with no
CloudFormation equivalent.

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `external_id` | External ID Opsima generated (UUID). Sensitive. | `string` | n/a | yes |
| `opsima_principal` | Opsima's AWS account ID (12 digits). Sensitive. | `string` | n/a | yes |
| `customer_short_id` | Short ID Opsima generated (10 hex chars). Sensitive. | `string` | n/a | yes |
| `organization_id` | Your AWS Organization ID (`o-xxxxxxxxxx`). | `string` | n/a | yes |
| `organization_root_id` | Your AWS Organization root ID (`r-xxxx`). | `string` | n/a | yes |
| `opsima_organizational_unit_id` | Existing OU (`ou-xxxx-xxxxxxxx`) to use instead of creating one. | `string` | `""` | no |
| `opsima_invoice_unit_arn` | Existing Invoice Unit ARN (Opsima creates one if empty). | `string` | `""` | no |
| `create_cur_bucket` | Create the CUR S3 bucket. | `bool` | `true` | no |
| `create_opsima_organizational_unit` | Create the Opsima OU (only if `opsima_organizational_unit_id` is empty). | `bool` | `true` | no |
| `enable_opsima_handshake` | Send the completion notice to Opsima (as a nested CloudFormation stack). | `bool` | `true` | no |
| `opsima_handshake_sns_topic_arn` | Override the handshake SNS topic. | `string` | Opsima's published topic | no |
| `cloudformation_stack_version` | Value reported to Opsima as `CloudFormationStackVersion`. | `string` | `"10"` | no |
| `role_name` | Name of the IAM role. | `string` | `"OpsimaRemoteAccessRole"` | no |
| `tags` | Extra tags merged onto every taggable resource. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| `role_arn` | ARN of `OpsimaRemoteAccessRole` (same as the CFN stack's `RoleArn` output). |

## Where this differs from the CloudFormation template

CloudFormation and Terraform don't map 1:1, so a few things were adapted
rather than translated literally:

- **`DeletionPolicy: RetainExceptOnCreate`** has no Terraform equivalent. The
  CUR bucket carries `lifecycle { prevent_destroy = true }` to approximate it,
  so `terraform destroy` (or removing it from config, or flipping
  `create_cur_bucket` to `false`) errors until you `terraform state rm` it
  first. The OU has no such guard — Terraform will delete it on destroy.
- **`AccessControl: BucketOwnerFullControl`** on the CUR bucket was dropped.
  Modern S3 buckets default to ACLs disabled (`BucketOwnerEnforced`), which
  already gives the bucket owner full control — no canned ACL needed. Add
  `aws_s3_bucket_ownership_controls` + `aws_s3_bucket_acl` back in if some
  downstream consumer truly requires ACLs.
- **`Custom::OpsimaHandshake`** (the SNS notification that tells Opsima's
  backend the role exists) is kept verbatim, but run as a one-resource nested
  CloudFormation stack via `aws_cloudformation_stack.opsima_handshake`.
  CloudFormation performs the publish exactly as it does for the original
  template — same payload, same Create/Update/Delete lifecycle — so nothing is
  reverse-engineered. The apply credentials need `cloudformation:CreateStack`
  / `UpdateStack` / `DeleteStack` / `DescribeStacks`; no `aws` CLI or extra
  Terraform provider is required. Set `enable_opsima_handshake = false` to skip
  it and onboard from Opsima's UI instead.
- Everything else (the role, its trust policy with the `sts:ExternalId`
  condition, the inline policy statements, the OU, and the bucket policy
  statements) is a direct, statement-for-statement translation of the
  original template.

## Security note

This role grants a third party (Opsima) `organizations:CreateAccount`,
`organizations:MoveAccount`, `sts:AssumeRole` into any
`OpsimaOrganizationAccountAccessRole`, and read access to your Cost & Usage
Reports. Review these permissions against your own policies before applying,
the same way you would before launching the original CloudFormation stack.
