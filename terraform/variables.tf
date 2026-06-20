variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name for the EKS cluster and associated resources"
  type        = string
  default     = "distributed-health"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS control plane"
  type        = string
  default     = "1.32"
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.small"
}

variable "node_desired_count" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 3
}

variable "node_min_count" {
  description = "Minimum number of worker nodes (for cluster autoscaler)"
  type        = number
  default     = 3
}

variable "node_max_count" {
  description = "Maximum number of worker nodes (for cluster autoscaler)"
  type        = number
  default     = 3
}

variable "enable_cloudfront" {
  description = <<-EOT
    Whether to build the CloudFront distribution (cloudfront.tf).
    Keep FALSE for Phase 1 (cluster provisioning) — the ALB does not exist yet,
    and the aws_lb data lookup would fail at plan time.
    Set TRUE for Phase 2, AFTER ArgoCD has created the Ingress and the LBC has
    provisioned the ALB:  terraform apply -var enable_cloudfront=true
  EOT
  type        = bool
  default     = false
}
