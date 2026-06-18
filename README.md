# infrastructure

Infrastructure-as-code for the **DistributedHealth** platform: Terraform to provision an
AWS EKS cluster, Kubernetes manifests (Kustomize) for all nine microservices, and ArgoCD
GitOps config to deploy them.

This repo is **infrastructure only** — no application code lives here. Each microservice has
its own repository and CI pipeline; those pipelines push image-tag bumps back into the `k8s/`
manifests here (see [CI/CD flow](#how-images-reach-the-cluster)).

> This is the single source of truth for cluster configuration. ArgoCD syncs the `k8s/`
> directory from the **`main`** branch, so anything not merged to `main` is not deployed.

---

## What's in this repo

```
infrastructure/
├── terraform/                  # AWS EKS cluster (VPC, EKS, AWS Load Balancer Controller)
│   ├── main.tf                 #   VPC + EKS module + destroy-time ALB cleanup hook
│   ├── helm.tf                 #   AWS Load Balancer Controller (IAM policy, IRSA, Helm install)
│   ├── variables.tf            #   region, cluster name, node count/type, k8s version
│   └── outputs.tf              #   cluster name, endpoint, kubeconfig command, VPC/OIDC ids
├── k8s/                        # Kubernetes manifests, deployed by ArgoCD via Kustomize
│   ├── kustomization.yaml      #   root entry point — references namespace + all 9 services
│   ├── namespaces/             #   the `distributed-health` namespace
│   ├── api-gateway/            #   each service: configmap, deployment, service, kustomization
│   │   └── ingress.yaml        #   the platform's single ALB ingress (see note below)
│   ├── authentication/         #   Keycloak (deployment named `keycloak`, secret `keycloak-secrets`)
│   ├── patient-service/        #   + firebase-service-account.json (gitignored)
│   ├── doctor-service/         #   + firebase-service-account.json (gitignored)
│   ├── appointment-service/
│   ├── notification-service/
│   ├── telemedicine-service/
│   ├── payment-service/
│   └── ai-service/
├── argocd/
│   ├── application.yaml         # ArgoCD Application — syncs k8s/ from the infra repo
│   └── monitoring.yaml          # kube-prometheus-stack (Prometheus + Grafana), optional
├── setup-secrets.sh             # creates all Kubernetes secrets from local .env.secret files (gitignored)
├── SECRETS_MANAGEMENT.md        # how secrets are handled under GitOps
└── .claude/context/             # deep-dive reference docs (see below)
```

### Deep-dive docs

The `.claude/context/` directory holds detailed references — read these when you need more
than the quick start below:

- **`terraform-eks-guide.md`** — full Terraform workflow, each component explained,
  provision/destroy details, manual LBC install fallback, cost estimate.
- **`eks-readiness-checklist.md`** — pre-flight audit: blockers, risks, secrets, monitoring,
  CI/CD review, and the canonical run order.
- **`image-registry.md`** — Docker Hub image flow and what an ECR migration would involve.

Secret handling is documented in [`SECRETS_MANAGEMENT.md`](SECRETS_MANAGEMENT.md).

---

## Architecture at a glance

- **Cloud:** AWS EKS in `us-east-1`, provisioned by Terraform (VPC across 2 AZs, a managed
  node group of 3× `t3.small`, single NAT gateway, Kubernetes 1.32).
- **Ingress:** a single internet-facing **ALB** created by the AWS Load Balancer Controller.
  It routes all traffic (`/`) to the `api-gateway` Service on port 3001. The Ingress
  manifest currently lives in `k8s/api-gateway/ingress.yaml` (a known deviation — by
  convention it belongs at `k8s/ingress/`; cosmetic, doesn't affect function).
- **GitOps:** ArgoCD watches this repo's `main` branch and syncs the `k8s/` manifests
  (self-heal + prune enabled). You normally do **not** `kubectl apply` by hand on EKS.
- **Images:** all services pull public images from Docker Hub (`amzalfoumi/*`); each service's
  `kustomization.yaml` pins an immutable short-SHA tag. No `imagePullSecrets` needed.
- **Databases:** every service uses an external MongoDB Atlas cluster (`mongodb+srv://` URIs
  in its `.env.secret`). There are no in-cluster databases.

### How images reach the cluster

Each microservice repo's CI builds its image, pushes `amzalfoumi/<svc>:<short-sha>` (and
`:latest`) to Docker Hub, then runs `kustomize edit set image` against this repo and commits
the pinned SHA to `main`. ArgoCD detects the commit and rolls out the new image. The `:latest`
tag in each `deployment.yaml` is only a fallback — the pinned tag in `kustomization.yaml` wins.

---

## Prerequisites

Install and configure these before you start:

| Tool | Purpose |
|---|---|
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | authenticated (`aws configure`) with rights to create VPC/EKS/IAM/ELB resources |
| [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.6 | provisions the cluster |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | interacts with the cluster |
| Bash | to run `setup-secrets.sh` (Git Bash / WSL on Windows) |

You also need these **secret files**, which are gitignored and must be obtained out-of-band
(they are not in the repo):

- `k8s/<service>/.env.secret` for each service that has one (8 of the 9 — `api-gateway` has none).
- `k8s/doctor-service/firebase-service-account.json` — the Firebase service-account JSON
  (doctor and patient share one Firebase project, so this single file serves both).
- `setup-secrets.sh` is itself gitignored; if it's missing, recreate it from the version
  documented alongside `SECRETS_MANAGEMENT.md`.

---

## Setup — provision and deploy to EKS

Run from the repo root. Full provisioning takes ~15 minutes.

### 1. Provision the cluster

```bash
cd terraform
terraform init        # one-time: download providers and modules
terraform plan        # preview
terraform apply        # VPC + EKS + AWS Load Balancer Controller (~15 min)
```

`terraform apply` installs the AWS Load Balancer Controller automatically (IAM policy, IRSA
role, and Helm release) — no manual steps. To override defaults, edit `terraform/variables.tf`
or pass `-var` flags (e.g. `-var node_instance_type=t3.medium`).

### 2. Wire up kubectl

`terraform output kubeconfig_command` prints the exact command; it is:

```bash
aws eks update-kubeconfig --name distributed-health --region us-east-1
kubectl get nodes        # confirm nodes are Ready
```

Use the **same IAM identity** that ran `terraform apply` — it's granted cluster-admin
automatically (`enable_cluster_creator_admin_permissions`).

### 3. Allow the cluster's egress IP in MongoDB Atlas

EKS nodes egress through a single NAT gateway with one Elastic IP, freshly allocated on every
`apply`. Atlas rejects connections from unknown IPs, so add it after each provisioning cycle:

```bash
aws ec2 describe-nat-gateways --region us-east-1 \
  --filter "Name=state,Values=available" \
  --query "NatGateways[].NatGatewayAddresses[].PublicIp" --output text
```

Add the printed IP under **Atlas → Network Access** (or use a temporary `0.0.0.0/0` for a
short demo).

### 4. Create the secrets

ArgoCD does not manage secrets (they're never committed). Create them imperatively from your
local `.env.secret` files before the first sync:

```bash
bash setup-secrets.sh                 # all services
bash setup-secrets.sh api-gateway     # or one/several specific services
```

This upserts one Kubernetes secret per service (plus `keycloak-secrets` for authentication)
and the `firebase-key-secret` file secret used by doctor- and patient-service. Without these,
those two pods stay stuck in `ContainerCreating`. See [`SECRETS_MANAGEMENT.md`](SECRETS_MANAGEMENT.md).

### 5. Install ArgoCD and deploy the platform

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl apply -f argocd/application.yaml          # syncs k8s/ — deploys all 9 services
# Optional (capacity permitting — see note): kubectl apply -f argocd/monitoring.yaml
```

ArgoCD now reconciles the cluster to match `k8s/` on `main`.

> **Monitoring is heavy.** `monitoring.yaml` installs the full kube-prometheus-stack, which
> can overflow a 3× t3.small node group when combined with the app pods + Keycloak + ArgoCD.
> Skip it for small demos, or bump `node_instance_type`/`node_desired_count` first.

### 6. Get the public URL

```bash
kubectl get ingress -n distributed-health
```

The ALB DNS name appears under `ADDRESS` once the controller has provisioned it (may take a
minute or two). That hostname is the platform's entrypoint.

---

## Verifying the deployment

```bash
kubectl get all -n distributed-health                       # all pods/services
kubectl get deployment -n kube-system aws-load-balancer-controller   # expect READY 2/2
kubectl logs -n distributed-health <pod-name>               # service logs
kubectl describe pod -n distributed-health <pod-name>       # debug a stuck pod
```

To view Grafana/Prometheus (if `monitoring.yaml` was applied) — they use NodePort and aren't
reachable through the ALB, so port-forward:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# Grafana default login: admin / admin123  (change for anything non-demo)
```

---

## Tearing down

`terraform destroy` is the single command to bring all costs to **$0**. A destroy-time hook
in `main.tf` first deletes the Ingress so the controller removes the ALB before the VPC is
torn down (otherwise the VPC delete fails on the lingering ALB).

```bash
cd terraform
terraform destroy
```

If the run prints a warning that ALBs still exist, delete them in **EC2 → Load Balancers** and
re-run `terraform destroy`. Full troubleshooting (stuck resources, orphan checks) is in
`terraform-eks-guide.md`.

---

## Cost

Roughly **~$0.22/hr** while running (EKS control plane $0.10/hr + 3× t3.small + NAT gateway +
ALB), and **$0.00** after `terraform destroy`. The intended pattern is *provision → demo →
destroy*. The EKS control plane has no free tier; node costs may be covered by AWS credits.
See the cost table in `terraform-eks-guide.md`.

---

## Local development (minikube)

EKS is the primary target, but the manifests also run on minikube for local dev. Two
differences apply **locally only** (don't commit them):

1. The ALB ingress won't work — enable nginx instead and swap the ingress class:
   ```bash
   minikube addons enable ingress
   ```
2. Build images into minikube's Docker daemon before applying:
   ```bash
   eval $(minikube docker-env)                 # Git Bash / Linux / Mac
   minikube docker-env | Invoke-Expression     # PowerShell
   docker build -t api-gateway:latest ../api-gateway
   ```

Then apply manifests directly (no ArgoCD):

```bash
kubectl apply -k k8s/                  # everything
kubectl apply -k k8s/api-gateway/      # a single service
```

---

## Conventions for changing manifests

Manifest rules (YAML, Kustomize, namespace, deployment, service, secrets, ingress) are
documented for contributors and AI agents in [`CLAUDE.md`](CLAUDE.md) and [`AGENTS.md`](AGENTS.md).
Key points: 2-space indentation (never tabs), quoted ConfigMap values, no `../` in
service-level kustomizations, `imagePullPolicy: IfNotPresent` and resource requests/limits on
every deployment, `ClusterIP` services only, and never commit real secret values. New services
get a folder mirroring `api-gateway/` and an entry in the root `k8s/kustomization.yaml`.
