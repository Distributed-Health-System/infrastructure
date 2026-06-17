# Image Registry: Docker Hub vs ECR

This document records the current image registry setup, how image tags flow from CI into the cluster, and what would need to change if migrating to ECR.

---

## Current Setup: Docker Hub (public repos)

All service images are published to Docker Hub under the `amzalfoumi` namespace:

```
amzalfoumi/api-gateway
amzalfoumi/patient-service
amzalfoumi/doctor-service
amzalfoumi/appointment-service
amzalfoumi/payment-service
amzalfoumi/notification-service
amzalfoumi/ai-service
amzalfoumi/telemedicine-service
amzalfoumi/authentication-service   ← Keycloak custom image
```

Images are **public**. EKS nodes can pull them without credentials or `imagePullSecrets`.

---

## How Image Tags Flow from CI to the Cluster

Each service lives in its own GitHub repository with its own GitHub Actions workflow. The workflow:

1. Builds the Docker image
2. Pushes it to Docker Hub with **two** tags: the git short-SHA *and* `latest`
   (e.g. `amzalfoumi/api-gateway:97c70f5` and `amzalfoumi/api-gateway:latest`)
3. Runs `kustomize edit set image <service>=amzalfoumi/<service>:<short-sha>` against this
   infrastructure repo — so the cluster is always pinned to the immutable SHA tag, never `latest`
4. Commits the updated `kustomization.yaml` back to this repo
5. ArgoCD detects the commit and syncs the cluster

This means the `latest` tag visible in the individual `deployment.yaml` files is only a **fallback placeholder**. In practice, the tag in the service-level `kustomization.yaml` is always a pinned build tag set by CI.

---

## Why `imagePullPolicy: IfNotPresent` Is Correct Here

Every CI build produces a **unique tag**. When EKS schedules a pod with a tag the node has never seen, it pulls the image regardless of `imagePullPolicy`. On subsequent restarts of the same pod (same tag), `IfNotPresent` skips the redundant pull — which is the desired behaviour.

`imagePullPolicy: Always` would be wrong here: it would re-pull on every pod restart even when nothing changed, wasting time and burning Docker Hub rate limits.

---

## Docker Hub Rate Limits

Docker Hub free tier limits:
- **Unauthenticated pulls:** 100 per 6 hours (per IP)
- **Authenticated free account:** 200 per hour

EKS nodes share public IPs via NAT gateway, so unauthenticated pulls aggregate across all nodes against the same IP limit. For a demo cluster with low churn this is unlikely to be hit, but a busy CI pipeline or a large node group could trigger it.

Mitigation (if needed without switching to ECR): add Docker Hub credentials as a Kubernetes Secret and reference it via `imagePullSecrets` in deployments.

---

## ECR: What Would Change

ECR is the natural fit for EKS because node IAM roles automatically get ECR pull permissions — no credentials required at all.

### Terraform changes

One `aws_ecr_repository` resource per service (9 total):

```hcl
resource "aws_ecr_repository" "api_gateway" {
  name         = "api-gateway"
  force_delete = true   # allows destroy even when images exist
}
```

Or with `for_each`:

```hcl
locals {
  services = [
    "api-gateway", "patient-service", "doctor-service",
    "appointment-service", "payment-service", "notification-service",
    "ai-service", "telemedicine-service", "authentication-service"
  ]
}

resource "aws_ecr_repository" "services" {
  for_each     = toset(local.services)
  name         = each.key
  force_delete = true
}
```

The EKS node group IAM role created by the EKS Terraform module already includes `AmazonEC2ContainerRegistryReadOnly` — no extra IAM changes needed.

### Image ref format

```
# Docker Hub (current)
amzalfoumi/api-gateway:abc123

# ECR
<account-id>.dkr.ecr.us-east-1.amazonaws.com/api-gateway:abc123
```

### CI workflow changes

Each service repo's workflow would need to:
1. Authenticate to ECR: `aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com`
2. Push to ECR instead of Docker Hub
3. Update the `kustomize edit set image` command to use the ECR URI

### Cost

- **Storage:** ~$0.10/GB/month. Nine Node.js images ≈ 2 GB compressed → ~$0.20/month.
- **Data transfer (EKS → ECR, same region):** **free**.
- No pull rate limits.

---

## Decision for This Project

**Docker Hub is sufficient for a demo.** Images are public, rate limits are unlikely to be hit for a single demo run, and no Terraform or CI changes are needed.

Switch to ECR if:
- The cluster runs continuously (rate limits become a real risk)
- Images need to be private
- The project is moving toward a production posture
