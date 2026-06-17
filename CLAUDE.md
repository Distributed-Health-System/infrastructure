# Infrastructure — Agent Rules

This repository contains all Kubernetes manifests for the DistributedHealth platform.
It is the single source of truth for cluster configuration.

---

## Stack

- Kubernetes manifests (plain YAML + Kustomize)
- **Primary target: AWS EKS** (provisioned via Terraform in `terraform/`, GitOps via ArgoCD).
  Cloud-specific annotations (e.g. AWS Load Balancer Controller `alb.ingress.kubernetes.io/*`)
  are expected and allowed.
- **Secondary: minikube** for local dev. When running locally, the ALB ingress won't work —
  swap to the nginx ingress class (`minikube addons enable ingress`) for that environment only.
- Kustomize via `kubectl apply -k` (no Helm for app manifests; Helm is used by Terraform/ArgoCD
  for the Load Balancer Controller and the monitoring stack)

---

## Folder Structure

```
k8s/
├── kustomization.yaml          ← root entry point, references all services and namespaces
├── namespaces/
│   └── namespace.yaml
├── api-gateway/
│   ├── kustomization.yaml
│   ├── configmap.yaml
│   ├── deployment.yaml
│   └── service.yaml
└── ingress/                    ← add later
    └── ingress.yaml
```

Add each new service as a sibling folder under `k8s/` following the same structure as `api-gateway/`.

---

## YAML Rules

1. **Always use spaces, never tabs.** YAML forbids tabs. Use 2 spaces per indent level.

2. **All numeric values in ConfigMaps must be quoted strings.**

   ```yaml
   PORT: "3001"       # ✅
   PORT: 3001         # ❌ — will be treated as integer, not string
   ```

3. **Do not use implicit booleans.** Quote them to be safe.

   ```yaml
   ENABLED: "true"    # ✅
   ENABLED: true      # ❌ — parsed as boolean, not string
   ```

4. **Keep each resource in its own file.** Do not put multiple `kind:` documents separated by `---` in one file unless there is a strong reason. It makes diffs and debugging harder.

5. **Always include `apiVersion` and `kind` at the top of every resource file.** Never omit them.

6. **Do not add trailing spaces or trailing newlines.** Keep files clean.

---

## Kustomize Rules

1. **A `kustomization.yaml` may only reference files within its own directory or below.**
   Never use `../` to reach a sibling or parent folder.

   ```yaml
   # ✅ CORRECT — inside k8s/api-gateway/kustomization.yaml
   resources:
     - configmap.yaml
     - deployment.yaml
     - service.yaml

   # ❌ WRONG — crosses directory boundary
   resources:
     - ../namespaces/namespace.yaml
   ```

2. **Cross-folder references belong in the root `k8s/kustomization.yaml` only.**

   ```yaml
   # k8s/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - namespaces/namespace.yaml
     - api-gateway
     - patient-service
   ```

3. **Every service folder must have its own `kustomization.yaml`** listing its own resources only.

4. **Set `namespace` in the service-level kustomization**, not in every individual manifest.
   ```yaml
   # k8s/some-service/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: distributed-health
   resources:
     - configmap.yaml
     - deployment.yaml
     - service.yaml
   ```

---

## Namespace Rules

1. All resources belong to the `distributed-health` namespace.
2. The namespace is defined once in `k8s/namespaces/namespace.yaml`. Do not redefine it elsewhere.
3. Never deploy anything into the `default` namespace.
4. Never modify `kube-system` or any other built-in namespace.

---

## Deployment Rules

1. **Always set `imagePullPolicy: IfNotPresent`.** CI builds a unique SHA-tagged image per
   commit, so a node only pulls a tag it hasn't seen; `IfNotPresent` then avoids redundant
   re-pulls (and saves Docker Hub rate limit). Works the same on EKS and minikube.

2. **Always include resource requests and limits.** Never omit them.

   ```yaml
   resources:
     requests:
       memory: "128Mi"
       cpu: "100m"
     limits:
       memory: "256Mi"
       cpu: "200m"
   ```

3. **Use `envFrom.configMapRef`** to inject config. Do not hardcode env vars inline in the deployment.

4. **Labels must be consistent** across Deployment selector, Pod template, and Service selector. The `app: <service-name>` label is the glue — if it drifts, the Service cannot find its pods.

   ```yaml
   # Deployment selector
   selector:
     matchLabels:
       app: api-gateway
   # Pod template
   template:
     metadata:
       labels:
         app: api-gateway   # must match exactly
   # Service selector
   selector:
     app: api-gateway       # must match exactly
   ```

5. **`replicas: 1` is fine for local dev.** Do not set it higher unless testing scaling behaviour.

6. **Never deploy the `latest` tag to the cluster.** Each service `kustomization.yaml` pins
   an immutable SHA tag (set by CI via `kustomize edit set image`); the `:latest` in
   `deployment.yaml` is only an overridden fallback. On EKS, ArgoCD always deploys the pinned
   SHA. (For minikube local dev, building `:latest` into the local daemon is acceptable.)

---

## Service Rules

1. **Type is `ClusterIP` for all internal services.** Do not use `NodePort` or `LoadBalancer`.
2. External access is handled exclusively by the Ingress.
3. `port` and `targetPort` must match the `containerPort` in the Deployment and `PORT` in the ConfigMap.
4. The Service `name` becomes the DNS hostname inside the cluster. Name it exactly as it appears in other services' `*_SERVICE_URL` env vars.
   ```yaml
   # If configmap has: PATIENT_SERVICE_URL: "http://patient-service:3002"
   # Then the Service must be named:
   metadata:
     name: patient-service # must match exactly
   ```

---

## ConfigMap and Secret Rules

1. **ConfigMap** — non-sensitive config only: URLs, ports, feature flags, timeouts.
2. **Secret** — anything sensitive: API keys, JWT secrets, database passwords, tokens.
3. **Never put secrets in a ConfigMap.**
4. **Never commit Secret manifests with real values to git.** Use placeholder values and document where real values come from.
   ```yaml
   # secret.yaml — safe to commit
   stringData:
     CLERK_SECRET_KEY: "REPLACE_ME"
   ```
5. Reference secrets in deployments via `envFrom.secretRef`, same pattern as ConfigMap.

---

## Ingress Rules

1. **EKS (primary): use the `alb` ingress class** with AWS Load Balancer Controller
   annotations. The controller provisions an internet-facing ALB. Current ingress:
   ```yaml
   metadata:
     annotations:
       alb.ingress.kubernetes.io/scheme: internet-facing
       alb.ingress.kubernetes.io/target-type: ip
       alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
   spec:
     ingressClassName: alb
   ```
   For production add an HTTPS listener + `alb.ingress.kubernetes.io/certificate-arn`.
2. **minikube (local only): use the `nginx` ingress class** (`minikube addons enable ingress`).
   Do not commit the nginx variant as the default — `alb` is the committed default.
3. ALB has **no CORS feature** — CORS must be handled in the api-gateway app, not via ingress
   annotations.
4. Ingress *should* live at `k8s/ingress/ingress.yaml` (root-level), referenced from the root
   `k8s/kustomization.yaml`. **Known deviation:** it currently lives in `k8s/api-gateway/`.
5. All services behind the ingress must be `ClusterIP` type.

---

## Applying Manifests

```bash
# Apply everything
kubectl apply -k k8s/

# Apply a single service only
kubectl apply -k k8s/api-gateway/

# Verify everything is running
kubectl get all -n distributed-health

# Check logs for a pod
kubectl logs -n distributed-health <pod-name>

# Describe a resource (useful for debugging)
kubectl describe pod -n distributed-health <pod-name>
```

On **EKS**, you normally don't `kubectl apply` by hand — ArgoCD syncs the manifests from Git.
The `kubectl apply -k` commands above are for direct/manual debugging. Provisioning,
kubeconfig, secrets, and the ArgoCD bootstrap are covered in
`.claude/context/eks-readiness-checklist.md` and `terraform-eks-guide.md`.

For **local development with minikube**, build images into minikube's Docker daemon first:

```bash
eval $(minikube docker-env)                   # Git Bash / Linux / Mac
minikube docker-env | Invoke-Expression       # PowerShell

docker build -t api-gateway:latest ../api-gateway
```

---

## Pre-Apply Checklist

- [ ] Indentation uses spaces, not tabs
- [ ] No `../` references inside a service-level `kustomization.yaml`
- [ ] New service added to root `k8s/kustomization.yaml`
- [ ] Resource requests and limits present in every deployment
- [ ] `imagePullPolicy: IfNotPresent` set in every deployment
- [ ] `namespace: distributed-health` set in service-level kustomization
- [ ] Labels are consistent across Deployment selector, Pod template, and Service selector
- [ ] Sensitive values are in Secrets, not ConfigMaps
- [ ] No real secret values committed to git
- [ ] Image built into minikube's Docker daemon
