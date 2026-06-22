# ---------------------------------------------------------------------------
# AWS Load Balancer Controller (installed as an EKS managed add-on)
#
# The controller watches Ingress resources and creates ALBs automatically.
# It needs IAM permissions to call the ELB/EC2 APIs; we grant those through an
# IRSA role (IAM Role for Service Accounts) bound to the controller's service
# account via the cluster's OIDC provider.
#
# The controller itself is installed as an `aws_eks_addon`, so this whole file
# uses only the `aws` provider — no `kubernetes` or `helm` providers required.
#
# The older Helm-based install (which needed the kubernetes + helm + http
# providers) is kept commented at the bottom of this file for reference.
# ---------------------------------------------------------------------------

locals {
  lbc_namespace = "kube-system"
  lbc_sa_name   = "aws-load-balancer-controller"
}

# ---------------------------------------------------------------------------
# IRSA — an IAM role carrying the controller's permissions, bound to its
# Kubernetes service account through the cluster's OIDC provider.
# The module bundles the official AWS Load Balancer Controller IAM policy
# (attach_load_balancer_controller_policy), so we don't fetch or attach it by
# hand — that replaces the old data.http + aws_iam_policy pair.
# ---------------------------------------------------------------------------

module "lbc_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name            = "AWSLoadBalancerController-${var.cluster_name}"
  use_name_prefix = false

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${local.lbc_namespace}:${local.lbc_sa_name}"]
    }
  }
}

# ---------------------------------------------------------------------------
# EKS managed add-on — installs and runs the controller in kube-system.
# AWS selects an add-on version compatible with the cluster's Kubernetes
# version. configuration_values wires the controller's service account to the
# IRSA role above (the same as serviceAccount.annotations in the Helm chart);
# clusterName, region, and vpcId are auto-detected by the managed add-on.
# ---------------------------------------------------------------------------

resource "aws_eks_addon" "lbc" {
  cluster_name = module.eks.cluster_name
  addon_name   = "aws-load-balancer-controller"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    serviceAccount = {
      name = local.lbc_sa_name
      annotations = {
        "eks.amazonaws.com/role-arn" = module.lbc_irsa.arn
      }
    }
  })

  depends_on = [module.eks, module.lbc_irsa]
}

# ---------------------------------------------------------------------------
# REFERENCE ONLY — older Helm-based install.
#
# This is how the controller was installed before moving to the EKS add-on.
# It needed three extra providers (kubernetes, helm, http) in providers.tf and
# created the IAM policy by fetching the upstream JSON. Kept here so the
# alternative is documented; do not enable alongside aws_eks_addon.lbc above.
#
# locals {
#   lbc_version       = "v2.14.1"
#   lbc_chart_version = "1.14.0"
# }
#
# data "http" "lbc_iam_policy" {
#   url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${local.lbc_version}/docs/install/iam_policy.json"
# }
#
# resource "aws_iam_policy" "lbc" {
#   name        = "AWSLoadBalancerControllerIAMPolicy-${var.cluster_name}"
#   description = "IAM policy for the AWS Load Balancer Controller"
#   policy      = data.http.lbc_iam_policy.response_body
# }
#
# resource "helm_release" "lbc" {
#   name       = "aws-load-balancer-controller"
#   repository = "https://aws.github.io/eks-charts"
#   chart      = "aws-load-balancer-controller"
#   version    = local.lbc_chart_version
#   namespace  = local.lbc_namespace
#
#   set {
#     name  = "clusterName"
#     value = module.eks.cluster_name
#   }
#   set {
#     name  = "serviceAccount.create"
#     value = "true"
#   }
#   set {
#     name  = "serviceAccount.name"
#     value = local.lbc_sa_name
#   }
#   set {
#     name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
#     value = module.lbc_irsa.arn
#   }
#   set {
#     name  = "region"
#     value = var.aws_region
#   }
#   set {
#     name  = "vpcId"
#     value = module.vpc.vpc_id
#   }
#
#   depends_on = [module.eks, module.lbc_irsa]
# }
# ---------------------------------------------------------------------------
