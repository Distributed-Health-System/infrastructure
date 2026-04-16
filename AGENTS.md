# Infrastructure — Agent Rules

> This file targets AI coding agents (Copilot, Cursor, Codex, etc.).
> For Claude specifically, see CLAUDE.md — both files contain the same rules.

This repository contains all Kubernetes manifests for the DistributedHealth platform.
Do not generate application code here. This repo is infrastructure only.

---

## What this repo is

- Kubernetes manifests for all DistributedHealth microservices
- Uses Kustomize (built into kubectl) — no Helm
- Targets minikube for local dev, must remain platform-agnostic (no cloud-specific annotations)

---

## Non-negotiable rules

These will cause immediate apply failures if violated. Check for all of them before outputting any file.

### 1. YAML indentation is spaces only — never tabs

YAML forbids tab characters. The error `found character that cannot start any token` means tabs are present.
Use exactly 2 spaces per indent level. No exceptions.

```yaml
# ✅ correct
metadata:
  name: api-gateway
  namespace: distributed-health

# ❌ will break — tabs
metadata:
	name: api-gateway
	namespace: distributed-health
```

### 2. Kustomization files cannot reference parent directories

Kustomize enforces a security boundary: a `kustomization.yaml` can only reference files at or below its own directory.
Using `../` will throw a security error at apply time.

```yaml
# ✅ correct — k8s/api-gateway/kustomization.yaml references its own files
resources:
  - configmap.yaml
  - deployment.yaml
  - service.yaml

# ❌ will break — crosses directory boundary
resources:
  - ../namespaces/namespace.yaml
```

Cross-folder references (like pointing to `namespaces/`) belong only in the root `k8s/kustomization.yaml`.

### 3. ConfigMap values must be quoted strings

```yaml
PORT: "3001"       # ✅ string
ENABLED: "true"    # ✅ string
PORT: 3001         # ❌ integer — will cause type errors in the app
ENABLED: true      # ❌ boolean — will cause type errors in the app
```

---

## File structure — follow this exactly

```
k8s/
├── kustomization.yaml               ← root, references namespaces + all service folders
├── namespaces/
│   └── namespace.yaml
├── api-gateway/
│   ├── kustomization.yaml
│   ├── configmap.yaml
│   ├── deployment.yaml
│   └── service.yaml
└── <new-service>/                   ← copy api-gateway structure for every new service
    ├── kustomization.yaml
    ├── configmap.yaml
    ├── deployment.yaml
    └── service.yaml
```

When adding a new service, also add it to the root `k8s/kustomization.yaml` resources list.

---

## Required content per file

### kustomization.yaml (service level)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: distributed-health
resources:
  - configmap.yaml
  - deployment.yaml
  - service.yaml
```

### deployment.yaml — required fields

- `imagePullPolicy: IfNotPresent` — always, for GitHub Actions-built images used with minikube
- `resources.requests` and `resources.limits` — always, never omit
- `envFrom.configMapRef` — inject config from ConfigMap, do not hardcode env vars inline
- Labels must match exactly across `spec.selector.matchLabels`, `template.metadata.labels`, and the Service selector

### service.yaml

- `type: ClusterIP` always — no NodePort, no LoadBalancer
- `name` must exactly match the hostname used in other services `*_SERVICE_URL` env vars
- `port` and `targetPort` must match `containerPort` in the deployment and `PORT` in the configmap

### configmap.yaml

- Non-sensitive values only (URLs, ports, flags)
- Sensitive values (API keys, tokens, passwords) go in `secret.yaml`

### secret.yaml (when needed)

- Use placeholder values only — never real credentials
- Document where real values come from in a comment

---

## Namespace

All resources belong to `distributed-health`. Never use `default` or any other namespace.
The namespace resource lives in `k8s/namespaces/namespace.yaml` — do not redefine it elsewhere.

---

## Pre-output checklist

Before generating any manifest file, verify:

- [ ] All indentation uses spaces, not tabs
- [ ] No `../` in service-level kustomization files
- [ ] Root `k8s/kustomization.yaml` updated if a new service was added
- [ ] `imagePullPolicy: IfNotPresent` in every deployment
- [ ] Resource requests and limits in every deployment
- [ ] Labels consistent across Deployment, Pod template, and Service
- [ ] ConfigMap values are quoted strings
- [ ] No real secret values in any file
