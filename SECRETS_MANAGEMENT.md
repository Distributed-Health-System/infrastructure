Secrets Management Guide

As a universal security best practice, we **never commit secrets** (like database passwords or API keys) to version control. 

Because we use **ArgoCD for GitOps**, ArgoCD synchronizes our Kubernetes state directly from this remote GitHub repository. It does not have access to the uncommitted local `.env.secret` files on your machine. Therefore, if we tried to use Kustomize's `secretGenerator` to build secrets, ArgoCD would fail because the required `.env.secret` files aren't available to it in the Git repository.

To solve this, secrets are created **imperatively (manually)** directly inside the Minikube cluster using our local `.env.secret` files.

How to Inject or Update a Secret

Whenever you set up the cluster for the first time, OR whenever you change a password in a local .env.secret file, you must run the following two steps in your terminal.

1. Apply the Secret to Kubernetes

Navigate to the directory in the services repos containing the .env.secret file you want to update. Run the following command to securely upsert (create or update) the secret in the cluster:

kubectl create secret generic <service-name>-secret \
  --from-env-file=.env.secret \
  -n distributed-health \
  --dry-run=client -o yaml | kubectl apply -f -


(Replace <service-name> with the actual name, e.g., appointment-service-secret)

2. Restart the Pods (Crucial for Updates)

Kubernetes pods only read secrets when they boot up. If you just updated an existing secret, ArgoCD will not automatically restart the pods. You must force a restart so the pods pull the fresh passwords. This command is completely safe and will not break ArgoCD's sync state:

kubectl rollout restart deployment <service-name> -n distributed-health


(Replace <service-name> with the actual deployment name, e.g., appointment-service)

Note on ArgoCD: ArgoCD will see that the pods restarted, but because the deployment.yaml in Git hasn't fundamentally changed, it will simply maintain its "Synced" and "Healthy" status.
