terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Note: the AWS Load Balancer Controller is installed as an EKS managed add-on
# (see lbc.tf), so no `kubernetes` or `helm` providers are needed here. The
# destroy-time ALB cleanup in main.tf shells out to `kubectl` via local-exec
# rather than using the kubernetes provider.
#
# The older Helm-based install required three more providers:
#   kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
#   helm       = { source = "hashicorp/helm",       version = "~> 2.0" }
#   http       = { source = "hashicorp/http",       version = "~> 3.0" }
# plus `provider "kubernetes"` and `provider "helm"` blocks that authenticated
# via `aws eks get-token`. See the reference block at the bottom of lbc.tf.
