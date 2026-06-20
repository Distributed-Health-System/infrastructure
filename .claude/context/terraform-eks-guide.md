# Terraform + AWS EKS Reference Guide

This document covers the Terraform workflow, required components, and AWS-specific configuration needed to provision and destroy the DistributedHealth platform on AWS EKS.

**Region: us-east-1 (N. Virginia)** — chosen because it has the lowest per-hour prices of any AWS region.

---

## Workflow Overview

The intended usage pattern is: **provision before demo → destroy after demo → cost goes to zero**.

CloudFront requires a **two-phase apply** because the ALB doesn't exist until after ArgoCD syncs the Ingress. Phase 1 builds the cluster; Phase 2 builds CloudFront on top of it.

```
# Phase 1 — provision cluster + LBC (~15 min)
terraform init      # one-time: download providers and modules
terraform plan      # preview what will be created/changed
terraform apply

# Wire kubectl and let ArgoCD deploy the app
aws eks update-kubeconfig --name distributed-health --region us-east-1
kubectl get ingress -n distributed-health   # wait until ADDRESS column is populated

# Phase 2 — build CloudFront now that the ALB exists
terraform apply -var enable_cloudfront=true   # only creates the CloudFront distribution
terraform output cloudfront_url             # your https://xxxxx.cloudfront.net entry point

# --- demo runs here ---

terraform destroy   # tear down everything, cost → $0
```

ArgoCD syncs the k8s manifests from `argocd/application.yaml` automatically after Phase 1.

---

## Terraform File Structure

All files live under `infrastructure/terraform/`.

```
terraform/
├── variables.tf    # all configurable inputs (region, cluster name, node count, instance type)
├── main.tf         # VPC + EKS cluster + destroy-time ALB cleanup hook
├── helm.tf         # AWS Load Balancer Controller — IAM policy, IRSA role, Helm install
├── cloudfront.tf   # CloudFront distribution — free HTTPS + CDN in front of the ALB
└── outputs.tf      # values printed after apply (cluster name, endpoint, cloudfront_url, …)
```

### `variables.tf`
Single source of truth for all configurable values. Every other file references `var.*` — nothing is hardcoded elsewhere. Key variables: `aws_region`, `cluster_name`, `kubernetes_version`, `node_instance_type`, `node_desired_count`.

### `main.tf`
Contains three logical sections:
- **Provider blocks** — configures the AWS, Kubernetes, and Helm providers. The Kubernetes and Helm providers authenticate using `aws eks get-token` at runtime, so they only resolve after the EKS cluster exists.
- **VPC module** — creates the network: private subnets (nodes), public subnets (load balancers), one NAT Gateway so nodes can pull images.
- **EKS module** — creates the control plane and managed node group (3× t3.small).
- **`terraform_data.cleanup_alb_before_destroy`** — a destroy-time hook that deletes Ingress objects so the LBC removes the ALB before Terraform tries to delete the VPC. Without this, the VPC destroy fails because the ALB still holds subnet references.

### `helm.tf`
Installs the AWS Load Balancer Controller entirely via Terraform — no manual commands needed:
1. Fetches the official IAM policy JSON from the controller's GitHub repo (`data.http`)
2. Creates the IAM policy in your AWS account (`aws_iam_policy`)
3. Creates an IAM role bound to a Kubernetes service account via OIDC — IRSA (`module.lbc_irsa`)
4. Installs the controller into `kube-system` via Helm (`helm_release.lbc`)

### `outputs.tf`
Prints after `terraform apply`:
- `cluster_name` — for `aws eks update-kubeconfig`
- `cluster_endpoint` — the EKS API server URL
- `kubeconfig_command` — the exact command to run, ready to copy-paste
- `vpc_id` — needed if troubleshooting ALB or security groups
- `oidc_provider_arn` — needed if you add IRSA for other services later
- `cloudfront_url` — the public HTTPS entry point (`https://xxxxx.cloudfront.net`); only populated after Phase 2 apply

---

## Destroying the Cluster

`terraform destroy` is the single command to bring all costs to zero. The destroy is fully automated — no manual steps required under normal conditions.

### What happens automatically

`main.tf` contains a `terraform_data.cleanup_alb_before_destroy` resource with a destroy-time provisioner. Terraform's destroy order ensures this runs first:

```
cleanup_alb_before_destroy  →  helm_release.lbc  →  module.eks  →  module.vpc
```

The provisioner:
1. Runs `aws eks update-kubeconfig` (re-authenticates kubectl to the still-running cluster)
2. Deletes all Ingress objects in the `distributed-health` namespace
3. The LBC sees the deletion and removes the ALB from AWS
4. Waits 60 seconds for AWS to fully remove the ALB
5. Checks via `aws elbv2 describe-load-balancers` whether any ALBs remain in the VPC
6. Prints a clear warning if any are still up, or confirms success

Normal output looks like:
```
==> Updating kubeconfig for cluster: distributed-health
==> Deleting Ingress resources (triggers LBC to remove the ALB)...
==> Waiting 60s for AWS to remove the ALB...
==> Checking for remaining ALBs in VPC: vpc-xxxxxxxxx
==> All ALBs removed. Safe to proceed with terraform destroy.
```

### If the WARNING appears (ALBs still up)

If the output contains:
```
WARNING: ALB(s) still exist — VPC destroy will fail unless removed manually.
Go to AWS Console > EC2 > Load Balancers and delete:
arn:aws:elasticloadbalancing:us-east-1:...
```

The VPC deletion will fail with a dependency error. Fix it manually:

1. Go to **AWS Console → EC2 → Load Balancers**
2. Find the ALB listed in the warning (match by ARN or name)
3. Select it → **Actions → Delete**
4. Re-run `terraform destroy` — it will pick up where it left off

### If terraform destroy itself gets stuck or partially fails

Terraform tracks state in `terraform.tfstate`. A partial destroy leaves some resources up. To identify what remains:

```bash
# See what Terraform still thinks exists
terraform state list

# Try destroy again — Terraform skips already-destroyed resources
terraform destroy
```

If a specific resource is stuck (e.g., a security group that AWS won't delete):
```bash
# Remove it from Terraform state without touching AWS (use as last resort)
terraform state rm <resource_address>
# Then delete it manually in the AWS Console
```

After any manual cleanup, verify nothing is left running:
```bash
# Check for remaining EKS clusters
aws eks list-clusters --region us-east-1

# Check for remaining load balancers in the region
aws elbv2 describe-load-balancers --region us-east-1 --query "LoadBalancers[].LoadBalancerName"

# Check for remaining NAT Gateways (they cost money even if idle)
aws ec2 describe-nat-gateways --region us-east-1 --filter "Name=state,Values=available" --query "NatGateways[].NatGatewayId"
```

---

## Component 1: VPC — `terraform-aws-modules/vpc/aws`

**Source:** https://github.com/terraform-aws-modules/terraform-aws-vpc

EKS requires a VPC with both public and private subnets across at least 2 availability zones. Private subnets host the nodes; public subnets host the load balancers.

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true   # allows private nodes to pull images
  single_nat_gateway   = true   # one NAT GW saves cost for demo use
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Required tags so EKS knows which subnets to use for load balancers
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    Project = var.cluster_name
  }
}
```

**Key outputs used downstream:** `module.vpc.vpc_id`, `module.vpc.private_subnets`

---

## Component 2: EKS Cluster — `terraform-aws-modules/eks/aws`

**Source:** https://github.com/terraform-aws-modules/terraform-aws-eks
**Current version:** `~> 21.0`
**Kubernetes version:** `1.32`

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    general = {
      instance_types = [var.node_instance_type]   # t3.small — 2 vCPU, 2GB
      min_size       = var.node_min_count          # 3
      max_size       = var.node_max_count          # 3
      desired_size   = var.node_desired_count      # 3
    }
  }

  tags = {
    Project = var.cluster_name
  }
}
```

**Key outputs:**
- `module.eks.cluster_name` — used in Helm and kubeconfig
- `module.eks.cluster_endpoint` — API server URL
- `module.eks.oidc_provider_arn` — required for IRSA
- `module.eks.cluster_certificate_authority_data` — for Kubernetes provider auth

---

## Component 3: AWS Load Balancer Controller

**Replaces:** `ingressClassName: nginx` in `k8s/ingress/ingress.yaml`
**Controller version:** v2.14.1 | **Helm chart version:** 1.14.0

The LBC watches Ingress resources and creates AWS Application Load Balancers automatically.

### Primary: Automated via `helm.tf`

All three steps (IAM policy, IRSA role, Helm install) run automatically as part of `terraform apply`. No manual commands needed.

Verify after apply:
```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
# Expected: READY 2/2
```

### Fallback: Manual installation (if `helm_release.lbc` fails in Terraform)

If the Terraform Helm install fails (e.g., timeout, provider auth issue), you can install the LBC manually after the cluster is up. These steps are fully valid and produce the same result.

**Step 1 — IAM Policy** (skip if the policy already exists from a partial apply)
```bash
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
```

**Step 2 — IRSA Service Account**

Requires `eksctl` installed. Replace `<AWS_ACCOUNT_ID>` with your account ID (find it with `aws sts get-caller-identity`).
```bash
eksctl create iamserviceaccount \
  --cluster=distributed-health \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::<AWS_ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --region us-east-1 \
  --approve
```

**Step 3 — Helm Install**

Replace `<vpc-id>` with the VPC ID from `terraform output vpc_id`.
```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=distributed-health \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-east-1 \
  --set vpcId=<vpc-id> \
  --version 1.14.0
```

**Step 4 — Verify**
```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
# Expected: READY 2/2
```

---

## Component 4: CloudFront — `cloudfront.tf`

**Added:** 2026-06-19

CloudFront sits in front of the ALB and provides:
- **Free HTTPS** via the `*.cloudfront.net` managed certificate — no domain, no ACM cert needed
- **A stable URL** that doesn't change between `terraform apply` cycles (unlike the ALB DNS)
- **Global edge caching** (currently pass-through / caching disabled — see Future Work note below)

### Why it's needed

We don't own a domain name. Getting a public TLS certificate directly on the ALB requires ACM, which requires proving you own a domain. CloudFront sidesteps this entirely — every distribution gets `https://<id>.cloudfront.net` with an AWS-managed cert pre-attached.

### Traffic flow

```
User --HTTPS--> CloudFront (free *.cloudfront.net cert)
                  --HTTP--> ALB (internal, unchanged)
                              --> Ingress --> api-gateway --> microservices
```

TLS terminates at CloudFront. The CloudFront → ALB hop stays HTTP because the ALB has no cert (no domain). That hop travels inside AWS's private backbone — not the public internet.

### How it finds the ALB

The ALB is created dynamically by the LBC (not by Terraform directly), so its hostname isn't known at write time. `cloudfront.tf` uses a `data "aws_lb"` lookup that finds it by the tags the LBC stamps:

```hcl
data "aws_lb" "ingress_alb" {
  tags = {
    "elbv2.k8s.aws/cluster" = var.cluster_name
    "ingress.k8s.aws/stack" = "distributed-health/api-gateway-ingress"
  }
}
```

This is why a two-phase apply is required — the ALB must exist before this lookup can succeed. The lookup (and the distribution) are gated behind `var.enable_cloudfront` (default `false`), with `count = var.enable_cloudfront ? 1 : 0`. **This gate is mandatory:** a data source is read at *plan* time and `aws_lb` errors if it matches zero load balancers — so without the flag, Phase 1 itself would fail at plan. Phase 2 runs `terraform apply -var enable_cloudfront=true`.

### Authorization header forwarding (critical)

CloudFront strips the `Authorization` header by default. This would silently break every JWT-authenticated request with a 401. The distribution uses the AWS-managed **AllViewer** origin request policy, which forwards all headers including `Authorization`.

### Current design: pass-through only

The distribution has a single catch-all behavior with `Managed-CachingDisabled`. Every request hits the ALB — nothing is cached. This is correct for a dynamic API gateway.

**Future work:** add an `ordered_cache_behavior` block matching static asset paths (e.g. `/_next/static/*`) with `Managed-CachingOptimized` to actually use the CDN for frontend static assets. Document in `cloudfront.tf` already.

### Destruction

`terraform destroy` removes the CloudFront distribution automatically. No manual steps needed. The ALB cleanup hook in `main.tf` still runs first (deletes Ingress → LBC removes ALB → VPC can be deleted cleanly).

---

## Ingress Change — DONE (2026-06-17)

`k8s/ingress/ingress.yaml` has been converted from nginx to ALB. It now uses:

```yaml
metadata:
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
spec:
  ingressClassName: alb
```

The old `nginx.ingress.kubernetes.io/*` CORS annotations were removed — ALB has no CORS
feature; CORS is handled in the api-gateway app (`src/main.ts`). Note its allowed origin
is hardcoded to `http://localhost:3000` and must be updated for the real frontend origin.

---

## Secrets Management on EKS

The existing `setup-secrets.sh` script works on EKS — just run it after `aws eks update-kubeconfig`.
It now also creates the `firebase-key-secret` file secret automatically (from
`k8s/doctor-service/firebase-service-account.json`), so no separate manual step is needed.

All secrets that must exist before ArgoCD sync:
- `api-gateway-secret`
- `keycloak-secrets`
- `patient-service-secret`
- `doctor-service-secret`
- `appointment-service-secret`
- `telemedicine-service-secret`
- `payment-service-secret`
- `notification-service-secret`
- `ai-service-secret`
- `firebase-key-secret` (JSON file mounted as volume in patient-service and doctor-service)

---

## Keycloak — Production Database Warning

Current config uses `KC_DB: "dev-mem"` (in-memory). This means **all users and sessions are wiped on pod restart**.

For demo purposes this is acceptable if you re-import users each demo. For persistent use, provision an AWS RDS PostgreSQL instance and update:
```yaml
KC_DB: "postgres"
KC_DB_URL: "jdbc:postgresql://<rds-endpoint>:5432/keycloak"
KC_DB_USERNAME: "<user>"
KC_DB_PASSWORD: "<password>"
```

---

## Cost Estimate (demo cluster, us-east-1)

us-east-1 has the lowest prices of any AWS region. These are pay-per-use — the cluster costs nothing when destroyed.

| Resource | Rate | Note |
|---|---|---|
| EKS control plane | $0.10/hr | No free tier — always charged |
| 3× t3.small nodes | $0.0208/hr each | $0.0624/hr total — see free tier note below |
| NAT Gateway | $0.045/hr + $0.045/GB | Single NAT GW to keep cost low |
| ALB | $0.008/hr + LCU charges | Created by Load Balancer Controller |
| **Total while running** | **~$0.215/hr** | Nodes may be $0 depending on account |
| **After `terraform destroy`** | **$0.00** | All resources removed |

**Node RAM:** 3× t3.small = 6GB total. After Kubernetes reserves ~460MB per node, usable capacity is ~4.6GB across the cluster. Keycloak's 1Gi limit fills most of one node — fine for short demos, tight for long runs.

**Free tier / credits:**
- **EKS control plane ($0.10/hr)** — no free tier, no credit exemption. Always charged.
- **t3.small nodes** — standard AWS Free Tier only covers t2.micro (750 hrs/month, 12 months). However, if your account has AWS credits (e.g., from AWS Educate, Activate for Startups, or other programmes), those credits apply and can cover t3.small costs. Check your account's credit balance at **AWS Console → Billing → Credits**.
- **NAT Gateway and ALB** — not covered by any free tier; charged by the hour.

---

## Quick Reference Commands

```bash
# Phase 1 — provision cluster + LBC
cd terraform && terraform init && terraform apply

# Wire kubectl (command also printed by terraform output)
aws eks update-kubeconfig --name distributed-health --region us-east-1

# Load secrets
bash setup-secrets.sh

# Install ArgoCD and apply app manifest
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f argocd/application.yaml

# Verify LBC is running
kubectl get deployment -n kube-system aws-load-balancer-controller

# Wait until the ALB is provisioned (ADDRESS column populated)
kubectl get ingress -n distributed-health

# Phase 2 — build CloudFront on top of the now-existing ALB
cd terraform && terraform apply -var enable_cloudfront=true
terraform output cloudfront_url   # → https://xxxxx.cloudfront.net (live in ~5-15 min)

# Quick smoke test (before opening in browser)
curl -I $(terraform output -raw cloudfront_url)

# Destroy everything (ALB cleanup + CloudFront removal run automatically)
cd terraform && terraform destroy
```
