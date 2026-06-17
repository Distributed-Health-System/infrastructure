# Project Reference: terraform-demo-USJ

This document is a complete, self-contained description of the `terraform-demo-USJ` repository. It is intended to be fed to Claude Code in another project so it can understand what exists here without reading the source files directly.

---

## Purpose

A two-phase Terraform demo on AWS, built for a USJ session. It demonstrates:
- The progression from **local state** to **remote S3 state**
- **S3 native locking** (Terraform >= 1.10, no DynamoDB required)
- **GitHub Actions automation** via **OIDC** (no long-lived AWS credentials)
- A **reusable workflow** pattern to avoid duplicating CI logic

There is no application code. The repo is entirely Terraform HCL + GitHub Actions YAML.

---

## Repository Layout

```
terraform-demo-USJ/
├── .github/
│   └── workflows/
│       ├── _reusable-terraform.yml   # Core logic — not triggered directly
│       ├── terraform-plan-apply.yml  # workflow_dispatch: plan or apply
│       └── terraform-destroy.yml     # workflow_dispatch: destroy
├── terraform-demo/
│   ├── 01-bootstrap/
│   │   ├── main.tf                   # Creates S3 remote-state bucket (local state)
│   │   └── .terraform.lock.hcl       # Provider lock file
│   └── 02-infrastructure/
│       ├── main.tf                   # Deploys VPC + EC2 (remote state in S3)
│       └── variables.tf              # instance_type variable (default: t3.micro)
├── .gitignore                        # Ignores .terraform/, *.tfstate, *.tfvars
├── CLAUDE.md                         # Claude Code guidance for this repo
├── README.md                         # Root overview + fork/setup instructions
└── terraform-demo/README.md          # Deep-dive: demo flow, architecture diagram, key concepts
```

---

## Phase 1 — Bootstrap (`terraform-demo/01-bootstrap/main.tf`)

**State:** LOCAL — `terraform.tfstate` lives on disk (gitignored)

**Purpose:** Create the S3 bucket that will store Phase 2's remote state.

**Terraform version:** `>= 1.10.0`  
**AWS provider:** `hashicorp/aws ~> 5.0`  
**Region:** `us-east-1`

### Resources created

| Resource | Name/ID | Notes |
|---|---|---|
| `aws_s3_bucket` | `terraform-state-<account-id>-demo` | `force_destroy = true` so it can be deleted even with state files inside |
| `aws_s3_bucket_versioning` | (same bucket) | `Enabled` — retains every state file version |
| `aws_s3_bucket_server_side_encryption_configuration` | (same bucket) | AES256, `bucket_key_enabled = true` |
| `aws_s3_bucket_public_access_block` | (same bucket) | All four block settings set to `true` |

**Bucket name formula:** `terraform-state-${data.aws_caller_identity.current.account_id}-demo`

### Outputs

- `state_bucket_name` — bucket name to paste into Phase 2 backend block
- `state_bucket_region` — always `us-east-1`
- `next_step` — human-readable instructions for Phase 2

### Default tags on all resources (via provider)

```hcl
ManagedBy   = "Terraform"
Environment = "Demo"
Project     = "terraform-state-demo"
```

---

## Phase 2 — Infrastructure (`terraform-demo/02-infrastructure/main.tf`)

**State:** REMOTE — S3 backend with native locking

**Purpose:** Deploy a VPC with a public EC2 web server.

**Terraform version:** `>= 1.10.0`  
**AWS provider:** `hashicorp/aws ~> 5.0`  
**Region:** `us-east-1`

### Backend block (hardcoded for the original account)

```hcl
backend "s3" {
  bucket       = "terraform-state-320026168830-demo"
  key          = "02-infrastructure/terraform.tfstate"
  region       = "us-east-1"
  encrypt      = true
  use_lockfile = true   # S3 native locking, no DynamoDB
}
```

> **Fork note:** Replace the bucket name with the output from Phase 1.

### Variable

```hcl
variable "instance_type" {
  type    = string
  default = "t3.micro"
}
```

### Data sources

- `aws_ami.amazon_linux_2023` — dynamic lookup for latest `al2023-ami-*-x86_64` AMI, owner `amazon`, state `available`

### Resources created (6 total)

| Resource | Name tag | Key settings |
|---|---|---|
| `aws_vpc.main` | `demo-vpc` | CIDR `10.0.0.0/16`, DNS hostnames + support enabled |
| `aws_subnet.public` | `demo-public-subnet` | CIDR `10.0.1.0/24`, AZ `us-east-1a`, `map_public_ip_on_launch = true` |
| `aws_internet_gateway.main` | `demo-igw` | Attached to VPC |
| `aws_route_table.public` | `demo-public-rt` | Route `0.0.0.0/0 → IGW` |
| `aws_route_table_association.public` | — | Associates public subnet with route table |
| `aws_security_group.web_server` | `demo-web-server-sg` | Ingress: 22 (SSH), 80 (HTTP), 443 (HTTPS) from `0.0.0.0/0`; Egress: all |
| `aws_instance.web_server` | `demo-web-server` | See detail below |

### EC2 instance detail

- **AMI:** dynamic (latest Amazon Linux 2023 x86_64)
- **Instance type:** `var.instance_type` (default `t3.micro`)
- **Subnet:** public subnet
- **Security group:** `demo-web-server-sg`
- **Public IP:** assigned
- **IMDSv2:** enforced (`http_tokens = "required"`, hop limit 1)
- **Root volume:** 8 GB gp3, encrypted, deleted on termination
- **user_data:** installs and starts Apache httpd via `dnf`, writes a static HTML page to `/var/www/html/index.html`

### Outputs

`vpc_id`, `public_subnet_id`, `security_group_id`, `ec2_instance_id`, `ec2_public_ip`, `ec2_public_dns`, `web_server_url` (`http://<public-ip>`), `ssh_command`, `ami_used`

### Default tags on all resources (via provider)

```hcl
ManagedBy   = "Terraform"
Environment = "Demo"
Project     = "terraform-infra-demo"
```

---

## GitHub Actions Workflows

### `_reusable-terraform.yml` — Reusable core

**Trigger:** `workflow_call` only (never triggered directly)

**Inputs:**
- `module` (required, string): `bootstrap` | `infrastructure`
- `action` (required, string): `plan` | `apply` | `destroy`

**Secrets:**
- `AWS_ROLE_ARN` (required)

**Permissions:** `id-token: write`, `contents: read`

**Runner:** `ubuntu-latest`

**Working directory logic:**
```
module == 'bootstrap'      → terraform-demo/01-bootstrap
module == 'infrastructure' → terraform-demo/02-infrastructure
```

**Steps:**
1. `actions/checkout@v4`
2. `aws-actions/configure-aws-credentials@v4` — OIDC role assumption, region `us-east-1`
3. `hashicorp/setup-terraform@v3` — version `~> 1.10`
4. `terraform init`
5. `terraform plan` (if action == plan)
6. `terraform apply -auto-approve` (if action == apply)
7. `terraform destroy -auto-approve` (if action == destroy)

---

### `terraform-plan-apply.yml`

**Trigger:** `workflow_dispatch`

**Inputs (both required, choice type):**
- `action`: `plan` | `apply`
- `module`: `bootstrap` | `infrastructure`

**Permissions:** `id-token: write`, `contents: read`

Delegates entirely to `_reusable-terraform.yml`.

---

### `terraform-destroy.yml`

**Trigger:** `workflow_dispatch`

**Inputs (required, choice type):**
- `module`: `infrastructure` | `bootstrap`  
  *(infrastructure listed first as a hint — always destroy it before bootstrap)*

**Permissions:** `id-token: write`, `contents: read`

Always calls `_reusable-terraform.yml` with `action: destroy`.

---

## AWS / OIDC Authentication

- GitHub gets a short-lived OIDC token per job
- Token is exchanged for temporary AWS credentials via the IAM role
- No long-lived secrets stored anywhere
- IAM role trust policy is scoped to a specific repo:
  ```json
  "token.actions.githubusercontent.com:sub": "repo:Nikila99gimhan/terraform-demo-USJ:*"
  ```
- Required IAM policies on the role: `AmazonS3FullAccess`, `AmazonEC2FullAccess`, `AmazonVPCFullAccess`
- Repository secret name: `AWS_ROLE_ARN` (value: the role ARN)

---

## Ordering Constraints

- **Bootstrap before infrastructure:** Phase 2 backend needs the S3 bucket from Phase 1
- **Destroy infrastructure before bootstrap:** If bootstrap bucket is deleted first, the Phase 2 state file is gone and Terraform loses track of the infrastructure

---

## .gitignore

```
.DS_Store
**/.DS_Store
.terraform/
**/.terraform/
*.tfstate
*.tfstate.backup
.terraform.tfvars
*.tfvars
```

State files are local-only; `.terraform/` provider caches are not committed. Only `.terraform.lock.hcl` is committed (it is not excluded).
