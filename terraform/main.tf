terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Providers
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region
}

# Both kubernetes and helm providers authenticate via the AWS CLI token exec.
# They reference the EKS module outputs so they only resolve after the cluster exists.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Required so EKS knows which subnets to use for each load balancer type
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

# ---------------------------------------------------------------------------
# EKS Cluster
# ---------------------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Grants the IAM identity running terraform kubectl admin access automatically
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    general = {
      instance_types = [var.node_instance_type]
      min_size       = var.node_min_count
      max_size       = var.node_max_count
      desired_size   = var.node_desired_count
    }
  }

  tags = {
    Project = var.cluster_name
  }
}

# ---------------------------------------------------------------------------
# Pre-destroy ALB cleanup
# Deletes the Ingress object before the LBC and cluster are torn down.
# The LBC sees the deletion and removes the ALB from AWS — without this,
# the VPC destroy fails because the ALB still holds subnet/SG references.
#
# Dependency chain (destroy order):
#   this resource → helm_release.lbc → module.eks → module.vpc
# ---------------------------------------------------------------------------

resource "terraform_data" "cleanup_alb_before_destroy" {
  triggers_replace = [module.eks.cluster_name, var.aws_region, module.vpc.vpc_id]

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      CLUSTER="${self.triggers_replace[0]}"
      REGION="${self.triggers_replace[1]}"
      VPC_ID="${self.triggers_replace[2]}"

      echo "==> Updating kubeconfig for cluster: $CLUSTER"
      aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

      echo "==> Deleting Ingress resources (triggers LBC to remove the ALB)..."
      kubectl delete ingress --all --namespace distributed-health --ignore-not-found

      echo "==> Waiting 60s for AWS to remove the ALB..."
      sleep 60

      echo "==> Checking for remaining ALBs in VPC: $VPC_ID"
      REMAINING=$(aws elbv2 describe-load-balancers \
        --region "$REGION" \
        --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" \
        --output text)

      if [ -n "$REMAINING" ]; then
        echo ""
        echo "WARNING: ALB(s) still exist — VPC destroy will fail unless removed manually."
        echo "Go to AWS Console > EC2 > Load Balancers and delete:"
        echo "$REMAINING"
        echo ""
      else
        echo "==> All ALBs removed. Safe to proceed with terraform destroy."
      fi
    EOT
    on_failure = continue
  }

  depends_on = [helm_release.lbc]
}
