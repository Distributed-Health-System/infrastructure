# EKS Readiness Checklist — DistributedHealth

Pre-flight audit for running the platform on AWS EKS (us-east-1), based on a full
read of the `infrastructure/` repo (all k8s manifests, kustomizations, terraform,
argocd apps) plus the per-service CI workflows. Ordered: **blockers** (deploy will
fail), then **important risks**, then **verify/nice-to-have**, then deep-dives on
**secrets**, **monitoring**, and **CI/CD**.

Last full audit: 2026-06-17.

---

## 🔴 Blockers — fix before `terraform apply` / first sync

### B1. Ingress still uses nginx, not ALB
`k8s/api-gateway/ingress.yaml` has `ingressClassName: nginx` plus `nginx.ingress.kubernetes.io/*`
CORS annotations. The AWS Load Balancer Controller **ignores** nginx ingresses, so
**no ALB is created and the platform has no external entrypoint**.

Fix — replace class + annotations:
```yaml
metadata:
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
spec:
  ingressClassName: alb
```
The nginx CORS annotations do nothing on ALB (ALB has no CORS feature). CORS is already
handled inside the api-gateway app, so dropping them is safe.

**Status: DONE on `dev`** (ingress converted to ALB). Verified the gateway sets CORS
itself at `api-gateway/src/main.ts:20`:
`app.enableCors({ origin: 'http://localhost:3000', credentials: true })`.

> **REMAINING ISSUE (B1 follow-up):** that allowed origin is **hardcoded to
> `http://localhost:3000`**. Once the frontend is served from a real origin (the ALB DNS,
> or the Vercel domain), browser requests will be **CORS-blocked** until `main.ts` is
> updated — ideally to read the allowed origin(s) from an env var (e.g. `CORS_ORIGIN`)
> wired through the api-gateway ConfigMap, rather than a hardcoded string. This lives in
> the api-gateway service repo, not infra, so it must be changed and redeployed there.

### B2. `firebase-key-secret` is never created
`doctor-service` and `patient-service` mount a volume from secret `firebase-key-secret`
(see deployment `volumes:` → `secretName: firebase-key-secret`, mounted at
`/app/secrets/firebase`, env `FIREBASE_SERVICE_ACCOUNT_PATH=/app/secrets/firebase/service-account.json`).
But `setup-secrets.sh` only creates **env-file** secrets — nothing creates this
**file** secret. Both pods stay in `ContainerCreating` (their `secretRef`s are also
**required**, not optional — see secrets section). This blocks two services.

**Status: DONE on `dev`** — `setup-secrets.sh` now creates `firebase-key-secret` from
`k8s/doctor-service/firebase-service-account.json` (key `service-account.json`) after the
env-file loop. doctor and patient share the same Firebase project (`distributed-health-5b963`),
so one secret serves both. Just run `bash setup-secrets.sh` after `update-kubeconfig`.

### B3. Branch split: CI writes `main`, you work on `dev`, ArgoCD tracks `HEAD`
- All 8 service CI workflows commit image-tag bumps to the **infra repo `main`**
  (`git push origin main`).
- `argocd/application.yaml` uses `targetRevision: HEAD` → ArgoCD syncs the repo's
  **default branch** (main).
- Your local infra checkout is on **`dev`**, where the B1/B2 fixes will land.

So manual fixes made on `dev` will **not deploy** unless merged to `main`, and CI keeps
moving `main` forward independently.

> **DECISION (2026-06-17):** Infra lives on **`main`** — `main` is the source of truth that
> ArgoCD (`targetRevision: HEAD`) and all CI workflows (`git push origin main`) use. Current
> work on `dev` will be **merged into `main` later**. Until that merge lands, the B1/B2 fixes
> and any other change on `dev` will NOT be deployed by ArgoCD. No `targetRevision` or
> workflow changes are needed — just remember to merge `dev` → `main` before relying on sync.

Mixing the two branches is the most likely "why didn't my change deploy" trap, which is
why we standardise on `main`.

### B4. MongoDB Atlas network access must allow the EKS NAT IP
There are **no MongoDB manifests** — every service's `.env.secret` uses an external
`mongodb+srv://` Atlas URI. EKS nodes egress through a **single NAT Gateway** with one
Elastic IP (`single_nat_gateway = true` in `main.tf`). Atlas rejects connections unless
that IP is in the project IP Access List.

After `terraform apply`:
```bash
aws ec2 describe-nat-gateways --region us-east-1 \
  --filter "Name=state,Values=available" \
  --query "NatGateways[].NatGatewayAddresses[].PublicIp" --output text
```
Add that IP in **Atlas → Network Access**. The NAT EIP is freshly allocated on every
`apply`, so re-add it each provisioning cycle (or use a temporary `0.0.0.0/0` for the demo).

---

## 🟠 Important risks

### R1. Node capacity is too small for the full stack + monitoring
3× t3.small = 6 GB total, ~4.6 GB usable after kube reservations (`variables.tf`).
Scheduled load: 9 backend pods + Keycloak (1Gi limit) + AWS LBC (2 replicas) + ArgoCD
(5 components) + **kube-prometheus-stack** (Prometheus ~1Gi+, Grafana, node-exporter,
kube-state-metrics). This will overflow → pods stuck `Pending` (Insufficient memory).
Options: bump `node_instance_type` to `t3.medium` (4 GB), raise `node_desired_count`, or
**skip `monitoring.yaml`** for the demo.

### R2. Keycloak hostname / issuer behind ALB
`KC_DB: dev-mem` + `start-dev --import-realm`: users/sessions are ephemeral (re-imported
each boot — acceptable for demo). Bigger issue: every URL is internal `http://keycloak:8080`.
Browser-facing OIDC login through the ALB needs `KC_HOSTNAME` set to the public ALB DNS
and the realm clients' redirect URIs updated, or login redirects break. Pure
server-to-server JWKS validation (gateway → `http://keycloak:8080`) is fine as-is.

### R3. ALB is HTTP-only and its DNS changes every apply
Ingress defines only HTTP:80, no ACM/TLS. The ALB DNS name is newly generated on every
`apply`. Consequences: **Stripe webhooks** (payment-service) need a stable public HTTPS
URL and must be re-pointed each demo; secure cookies / some browser APIs need HTTPS. For
real payments add an ACM cert (`alb.ingress.kubernetes.io/certificate-arn`) + Route53.

---

## 🟡 Verify / nice-to-have

- **Image tags: all 9 pinned.** Every service `kustomization.yaml` now carries an
  `images:` SHA pin (api-gateway `97c70f5`, ai `72062ab`, payment `e2d47db`,
  doctor/patient/appointment `484050b`, notification `57a062b`, telemedicine `25a2b1b`,
  authentication `d4c9e79`). The stale `MICROSERVICE_INFRA_AUDIT.md` claim that ai/payment
  lack pins is **no longer true**. The `:latest` in each `deployment.yaml` is an overridden
  fallback. → No action; just don't trust the old audit file.
- **Images are public on Docker Hub** (`amzalfoumi/*`) → no `imagePullSecrets` needed. See
  `image-registry.md`. Watch Docker Hub anonymous pull limits (100 / 6h / IP) aggregated
  behind the single NAT IP — low risk for one demo.
- **Ingress placement** still violates the infra repo rule (should live at
  `k8s/ingress/`, not inside `api-gateway/`). Cosmetic; doesn't affect function.
- **Secrets are gitignored** (`**/*.env.secret`, `firebase-service-account.json`,
  `setup-secrets.sh`); `git status` clean. No real secrets tracked. Good.
- **Grafana/Prometheus use NodePort** (30030/30090) — not reachable through the ALB and
  blocked by node SGs by default. Use `kubectl port-forward` to view them.
- **EKS secrets-at-rest encryption (KMS) is not enabled** in the EKS module — secrets sit
  base64-only in etcd. Acceptable for a throwaway demo; enable for production.

---

## Secrets management — validity assessment

**Verdict: structurally sound and GitOps-correct, with one blocking gap (B2) and some
inconsistency.**

What's right:
- Imperative creation via `setup-secrets.sh` (`kubectl create secret --from-env-file …
  --dry-run | kubectl apply`) keeps secret *values* out of Git. Because these secrets are
  **not tracked by ArgoCD**, `prune: true` won't delete them — so the imperative approach
  is fully compatible with the automated sync. This is the right call for the constraint.
- 8 services have `k8s/<svc>/.env.secret`; `api-gateway` intentionally has none (all its
  config is non-sensitive, in the ConfigMap; its `secretRef` is `optional: true`).
- `authentication` is special-cased correctly (secret `keycloak-secrets`, deployment
  `keycloak`).

Problems / inconsistencies:
1. **B2 — `firebase-key-secret` not created** (file secret, see above). Top priority.
2. **Inconsistent `optional:` on `secretRef`.** Required (no `optional`): doctor, patient,
   appointment. Optional: api-gateway, notification, ai, payment, telemedicine. A required
   ref with a missing secret hard-fails the pod; an optional one silently starts with no
   env. Pick one policy per service deliberately rather than by accident.
3. **Plaintext on disk + base64 in etcd.** Fine for demo; for production move to AWS
   Secrets Manager + External Secrets Operator, or SOPS/Sealed Secrets, and enable EKS KMS
   envelope encryption.
4. **`argocd/.env.secret`** stores the ArgoCD admin password in plaintext (gitignored,
   local only) — acceptable, just don't commit it.

The `SECRETS_MANAGEMENT.md` doc is accurate but mintions only minikube and omits the
firebase file-secret step — update it alongside the script.

---

## Monitoring — is it actually set up?

**No — installed but not wired to the applications.** `argocd/monitoring.yaml` deploys
`kube-prometheus-stack` (v61.3.0) via ArgoCD/Helm. Its `additionalScrapeConfigs` scrapes
pods in `distributed-health` **only if** they carry annotation
`prometheus.io/scrape: "true"` and reads the port from `prometheus.io/port`.

Two reasons no app metrics will appear:
1. **No deployment has any `prometheus.io/*` annotations** (grep across `k8s/` = zero hits).
   So the scrape config keeps nothing.
2. **No service exposes a metrics endpoint** — no `prom-client`, `@willsoto/nestjs-prometheus`,
   or `/metrics` anywhere in any `package.json`. Even if annotated, scrapes would 404.

What you *do* get: cluster/node metrics (node-exporter) and Kubernetes object metrics
(kube-state-metrics) in Grafana. What's missing: all per-service application metrics.

To make it real:
1. Add a Prometheus client to each service and expose `/metrics` (NestJS:
   `@willsoto/nestjs-prometheus` + `PrometheusModule`; Express payment-service: `prom-client`).
2. Add to each deployment's **pod template** metadata:
   ```yaml
   template:
     metadata:
       annotations:
         prometheus.io/scrape: "true"
         prometheus.io/port: "<containerPort>"
         prometheus.io/path: "/metrics"
   ```
3. Mind R1 — the stack is heavy for t3.small.

---

## CI/CD — pipeline review

All 8 service repos share one workflow shape (build → push → GitOps bump):
trigger on push to `main` → build image → push `amzalfoumi/<svc>:latest` and `:<short_sha>`
to Docker Hub → checkout infra repo → `kustomize edit set image …:<short_sha>` →
commit + `git pull --rebase` + `git push origin main`. clinical-services uses `paths:`
filters so each of its 4 services builds independently; standalone repos don't need that.

Required GitHub secrets: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `INFRA_REPO_PAT`
(PAT with write access to the infra repo).

Issues / blockers:
1. **`kustomize` is invoked but never installed** in any workflow. GitHub `ubuntu-latest`
   does **not** guarantee `kustomize` on PATH. The committed SHA pins prove the workflows
   have succeeded at least once, so the runner image may currently provide it — but this is
   fragile. Add an explicit install step (e.g. a setup-kustomize action) to be safe.
2. **Branch coupling (same as B3).** Workflows hardcode `origin main` for both the rebase
   and push. If you move ArgoCD to `dev`, every workflow must change too. Keep infra on
   `main` to avoid this.
3. **Concurrent pushes race.** Multiple service builds pushing to infra `main` at once rely
   only on `git pull --rebase`; simultaneous runs can still fail the push. Add a
   `concurrency:` group per workflow, or accept the occasional re-run.
4. **No test/lint gate.** Workflows build and ship on every push to `main` with no
   `npm test`/`lint` step — a bad commit ships straight to the cluster. Add a test job
   before build for safety.
5. **PR builds are build-only** (`push: false` when `event_name != 'push'`) — correct, no
   accidental publishes from PRs.

---

## Corrected run order

```bash
cd infrastructure/terraform
terraform init
terraform apply                                   # ~15 min: VPC + EKS + LBC

aws eks update-kubeconfig --name distributed-health --region us-east-1
kubectl get nodes                                 # confirm Ready (same IAM identity as apply)

# Add the NAT EIP to Atlas Network Access (B4)

bash ../setup-secrets.sh                           # AFTER adding the firebase-key-secret step (B2)

kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f ../argocd/application.yaml         # ensure targetRevision == the branch CI pushes (B3)
# Optional, capacity permitting: kubectl apply -f ../argocd/monitoring.yaml   (R1)

kubectl get ingress -n distributed-health          # grab ALB DNS once provisioned (needs B1 fixed)
# Update Stripe webhook URL to the ALB DNS (R3)

# --- demo ---

terraform destroy                                  # ALB cleanup runs automatically → $0
```
