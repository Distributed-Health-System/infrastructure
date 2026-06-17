# infrastructure

Kubernetes manifests (Kustomize) and Terraform for the DistributedHealth platform.

Previously tested on minikube; now targeting **AWS EKS**, provisioned with Terraform
(`terraform/`) and deployed via ArgoCD GitOps.

See `.claude/context/` for the deep-dive docs:
- `eks-readiness-checklist.md` — pre-flight blockers, secrets, monitoring, CI/CD, capacity
- `terraform-eks-guide.md` — Terraform workflow, provision/destroy, cost
- `image-registry.md` — Docker Hub image flow and ECR migration notes

Secret handling is documented in `SECRETS_MANAGEMENT.md`.
