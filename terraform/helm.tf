# ---------------------------------------------------------------------------
# AWS Load Balancer Controller
# Watches Ingress resources and creates ALBs automatically.
# Requires an IAM policy + IRSA role so the controller can call AWS APIs.
# ---------------------------------------------------------------------------

locals {
  lbc_version       = "v2.14.1"
  lbc_chart_version = "1.14.0"
  lbc_namespace     = "kube-system"
  lbc_sa_name       = "aws-load-balancer-controller"
}

# ---------------------------------------------------------------------------
# IAM Policy — grants the controller permission to manage ALBs/NLBs/TGs
# ---------------------------------------------------------------------------

data "http" "lbc_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${local.lbc_version}/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "lbc" {
  name        = "AWSLoadBalancerControllerIAMPolicy-${var.cluster_name}"
  description = "IAM policy for the AWS Load Balancer Controller"
  policy      = data.http.lbc_iam_policy.response_body
}

# ---------------------------------------------------------------------------
# IRSA — binds the IAM policy to a Kubernetes service account via OIDC
# ---------------------------------------------------------------------------

module "lbc_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "AWSLoadBalancerController-${var.cluster_name}"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${local.lbc_namespace}:${local.lbc_sa_name}"]
    }
  }
}

# ---------------------------------------------------------------------------
# Helm release — installs the controller into kube-system
# ---------------------------------------------------------------------------

resource "helm_release" "lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = local.lbc_chart_version
  namespace  = local.lbc_namespace

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = local.lbc_sa_name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.lbc_irsa.iam_role_arn
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  depends_on = [module.eks, module.lbc_irsa]
}
