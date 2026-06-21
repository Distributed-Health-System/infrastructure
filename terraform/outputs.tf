output "cluster_name" {
  description = "EKS cluster name — use in aws eks update-kubeconfig"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Run this after terraform apply to wire up kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "vpc_id" {
  description = "VPC ID — useful for manual LBC installs or other VPC-scoped resources"
  value       = module.vpc.vpc_id
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN — used for IRSA (IAM Roles for Service Accounts), e.g. the LBC role in lbc.tf"
  value       = module.eks.oidc_provider_arn
}

output "cloudfront_url" {
  description = "Public HTTPS entry point (free *.cloudfront.net cert). Point the frontend's API base URL here. Live ~5-15 min after apply."
  value       = var.enable_cloudfront ? "https://${aws_cloudfront_distribution.edge[0].domain_name}" : "(not built — Phase 2: terraform apply -var enable_cloudfront=true)"
}
