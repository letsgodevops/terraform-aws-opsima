# terraform-aws-opsima

Terraform re-implementation of Opsima's "full access" onboarding, packaged as a
reusable module.

It creates:

- An optional S3 bucket for Cost & Usage Reports (`opsima-cur-<customer_short_id>`)
  with a bucket policy that denies insecure transport and allows the
  `bcm-data-exports.amazonaws.com` service to write reports.
- The Opsima Organizational Unit (`opsima-<customer_short_id>`) for
  Opsima-managed accounts. Always created by this module — it is the boundary
  the security model depends on, so it is not an input.
- The `OpsimaRemoteAccessRole` IAM role (assumable only by Opsima's account,
  gated by an external ID) and its inline policy.

Onboarding is finished by pasting the `role_arn` and `organizational_unit_id`
outputs into Opsima's UI. The old `Custom::OpsimaHandshake` SNS notification is
**not** implemented — it required a nested CloudFormation stack, which we don't
ship.

## Usage

Apply this module from your AWS Organization's **management account**, same as the original
CloudFormation stack - the OU, `organizations:CreateAccount`, and `MoveAccount`
all require that.

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

module "opsima" {
  source = "git::https://github.com/<you>/terraform-aws-opsima.git//modules/opsima?ref=v1.0.0"

  # Values Opsima gave you when you started the "connect AWS account" flow.
  external_id       = var.opsima_external_id
  opsima_principal  = var.opsima_principal
  customer_short_id = var.opsima_customer_short_id

  # From your AWS Organization (or `data "aws_organizations_organization"`).
  organization_id      = var.organization_id
  organization_root_id = var.organization_root_id

  tags = {
    environment = "shared"
    managed_by  = "terraform"
  }
}

output "opsima_role_arn" {
  value = module.opsima.role_arn
}

output "opsima_ou_id" {
  value = module.opsima.organizational_unit_id
}

# The var.* placeholders above have to be declared. Pass the values with a
# tfvars file, -var flags, or TF_VAR_ environment variables.
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
```

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `external_id` | External ID Opsima generated (UUID). Sensitive. | `string` | n/a | yes |
| `opsima_principal` | Opsima's AWS account ID (12 digits). Sensitive. | `string` | n/a | yes |
| `customer_short_id` | Short ID Opsima generated (10 hex chars). Sensitive. | `string` | n/a | yes |
| `organization_id` | Your AWS Organization ID (`o-xxxxxxxxxx`). | `string` | n/a | yes |
| `organization_root_id` | Your AWS Organization root ID (`r-xxxx`). | `string` | n/a | yes |
| `create_cur_bucket` | Create the CUR S3 bucket. | `bool` | `true` | no |
| `role_name` | Name of the IAM role. | `string` | `"OpsimaRemoteAccessRole"` | no |
| `tags` | Extra tags merged onto every taggable resource. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| `role_arn` | ARN of `OpsimaRemoteAccessRole`. Paste into Opsima's UI. |
| `organizational_unit_id` | ID of the Opsima OU (the handshake used to send this to Opsima). |

## Security model

The role hands a third party (Opsima) organization-level permissions. The
Opsima OU is the boundary: the risky grants are scoped, via
`aws:ResourceOrgPaths`, so they can only reach accounts at the org root or
inside the Opsima OU — never accounts sitting in your own OUs.

- **`organizations:MoveAccount`** — the account being moved must currently be
  at the org root or already inside the Opsima OU. An account in one of your
  own OUs matches neither, so Opsima can't pull it out.
- **`sts:AssumeRole` into `OpsimaOrganizationAccountAccessRole`** is allowed
  only in accounts that live under the Opsima OU, not any account in the org
  that happens to have a role by that name.
- The trust policy only lets Opsima's account assume the role, and only with
  the `sts:ExternalId` Opsima issued you.

Opsima never gets `iam:*`, `organizations:LeaveOrganization`,
`organizations:RemoveAccountFromOrganization`, billing write access outside
invoice units, or any path to your root credentials.

### Residual risk / defence in depth

The `aws:ResourceOrgPaths` scoping assumes your production and management
accounts live in their own OUs, **not directly at the org root** — Opsima can
move and assume into anything sitting at the root. So:

- Keep no account you care about directly under the org root; put them in OUs.


## Where this differs from the CloudFormation template

- **`Custom::OpsimaHandshake`** is dropped. It published to an Opsima-owned SNS
  topic via a custom-resource Lambda; there is no native Terraform primitive
  for it and we don't ship CloudFormation. Finish onboarding from Opsima's UI
  with the `role_arn` and `organizational_unit_id` outputs.
- **The OU is mandatory and module-owned.** The CFN template let you pass an
  existing OU id or skip it; here it is always created, because the IAM policy
  scoping is anchored to it.
- **`DeletionPolicy: RetainExceptOnCreate`** on the CUR bucket is approximated
  with `lifecycle { prevent_destroy = true }`, so `terraform destroy` (or
  flipping `create_cur_bucket` to `false`) errors until you `terraform state rm`
  the bucket first. The OU has no such guard.
- **`AccessControl: BucketOwnerFullControl`** on the CUR bucket was dropped —
  modern S3 buckets default to ACLs disabled (`BucketOwnerEnforced`), which
  already gives the owner full control.
- The `MoveAccount` and `AssumeRole` statements are **tightened** relative to
  the CFN template (see Security model); everything else is a
  statement-for-statement translation.
