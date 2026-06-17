# Terraform + AWS EKS Reference Guide

This document covers the Terraform workflow, required components, and AWS-specific configuration needed to provision and destroy the DistributedHealth platform on AWS EKS.

**Region: us-east-1 (N. Virginia)** — chosen because it has the lowest per-hour prices of any AWS region. Note: AWS Free Tier is account-wide and does not vary by region. EKS control plane and t3.medium nodes are NOT covered by the free tier — costs are real but minimised by using us-east-1 and destroying the cluster after each demo.

---

## Workflow Overview

The intended usage pattern is: **provision before demo → destroy after demo → cost goes to zero**.

```
terraform init      # one-time: download providers and modules
terraform plan      # preview what will be created/changed
terraform apply     # provision all AWS resources (~15 min)

# --- demo runs here ---

terraform destroy   # tear down everything, cost → $0
```

After `apply`, wire up kubectl:
```bash
aws eks update-kubeconfig --name distributed-health --region us-east-1
kubectl get nodes   # verify cluster is up
```

ArgoCD then syncs the k8s manifests from `argocd/application.yaml` automatically.

---

## Terraform File Structure (to be created under `terraform/`)

```
terraform/
├── main.tf         # VPC + EKS cluster + node group
├── variables.tf    # region, cluster name, instance type, k8s version
├── outputs.tf      # cluster endpoint, OIDC ARN, kubeconfig command
└── helm.tf         # AWS Load Balancer Controller via Helm provider
```

---

## Component 1: VPC — `terraform-aws-modules/vpc/aws`

**Source:** https://github.com/terraform-aws-modules/terraform-aws-vpc

EKS requires a VPC with both public and private subnets across at least 2 availability zones. Private subnets host the nodes; public subnets host the load balancers.

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "distributed-health-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
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
    "kubernetes.io/cluster/distributed-health" = "shared"
    Project = "distributed-health"
  }
}
```

**Key outputs used downstream:** `module.vpc.vpc_id`, `module.vpc.private_subnets`

---

## Component 2: EKS Cluster — `terraform-aws-modules/eks/aws`

**Source:** https://github.com/terraform-aws-modules/terraform-aws-eks  
**Current version:** `~> 21.0`  
**Supported Kubernetes version:** `1.33` (latest as of 2026)

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "distributed-health"
  kubernetes_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    general = {
      instance_types = ["t3.small"]    # 2 vCPU, 2GB — 3 nodes gives 6GB total across cluster
      min_size       = 3
      max_size       = 3
      desired_size   = 3
    }
  }

  tags = {
    Project = "distributed-health"
  }
}
```

**Key outputs:**
- `module.eks.cluster_name` — used in helm and kubeconfig
- `module.eks.cluster_endpoint` — API server URL
- `module.eks.oidc_provider_arn` — required for IAM Roles for Service Accounts (IRSA)
- `module.eks.cluster_certificate_authority_data` — for Kubernetes provider auth

---

## Component 3: AWS Load Balancer Controller

**Replaces:** the `ingressClassName: nginx` in `k8s/api-gateway/ingress.yaml`  
**Docs:** https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html  
**Controller version:** v2.14.1  
**Helm chart version:** 1.14.0

The LBC watches Ingress resources and creates an AWS Application Load Balancer (ALB) automatically. It requires:
1. An IAM policy downloaded from the controller GitHub repo
2. An IAM role bound to a Kubernetes service account via OIDC (IRSA)
3. Helm install into `kube-system`

### Step 1 — IAM Policy (run once per AWS account)
```bash
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
```

### Step 2 — IAM Service Account (run once per cluster)
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

### Step 3 — Helm Install
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

### Step 4 — Verify
```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
# Expected: READY 2/2
```

---

## Ingress Change Required

The existing ingress at `k8s/api-gateway/ingress.yaml` uses `ingressClassName: nginx`.  
For EKS with ALB, change it to:

```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    # Update CORS origin to real frontend domain:
    # alb.ingress.kubernetes.io/...
spec:
  ingressClassName: alb   # replaces: nginx
```

---

## Secrets Management on EKS

The existing `setup-secrets.sh` script works on EKS — just run it after `aws eks update-kubeconfig`.

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
| 3× t3.small nodes | $0.0208/hr each | $0.0624/hr total for all 3 nodes |
| NAT Gateway | $0.045/hr + $0.045/GB | Single NAT GW to keep cost low |
| ALB | $0.008/hr + LCU charges | Created by Load Balancer Controller |
| **Total while running** | **~$0.215/hr** | |
| **After `terraform destroy`** | **$0.00** | All resources removed |

**Node RAM:** 3× t3.small = 6GB total. After Kubernetes reserves ~460MB per node, usable capacity is ~4GB across the cluster. Tight for long runs (Keycloak's 1Gi limit fills most of one node), but fine for short demos.

**Free tier reality:** AWS Free Tier is account-wide (not region-specific). EKS control plane has no free tier. The $0.10/hr control plane cost is always charged regardless of instance type or account age.

---

## Quick Reference Commands

```bash
# Provision
cd terraform && terraform init && terraform apply

# Wire kubectl
aws eks update-kubeconfig --name distributed-health --region us-east-1

# Load secrets
bash setup-secrets.sh

# Install LBC (after cluster up)
helm install aws-load-balancer-controller ...

# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f argocd/application.yaml

# Destroy everything
cd terraform && terraform destroy
```
