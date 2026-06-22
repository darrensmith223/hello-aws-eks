# dev Terraform environment

This environment is intentionally split into ordered Terraform layers so EKS infrastructure and Kubernetes platform resources do not share one state lifecycle.

## Layers

Apply in this order:

1. `aws` - VPC, EKS, IAM/IRSA, ACM, shared AWS outputs
2. `platform-core` - AWS Load Balancer Controller only
3. `platform-services` - External Secrets, ArgoCD, Kubernetes storage class
4. `platform-bootstrap` - CRD-backed resources and records that depend on the services above

Destroy in the reverse order:

1. `platform-bootstrap`
2. `platform-services`
3. `platform-core`
4. `aws`

The root `deploy.ps1` and `destroy.ps1` scripts implement this ordering.

## Why this split exists

Some Terraform resources require Kubernetes CRDs or admission webhooks to exist before Terraform can even plan successfully. For example:

- `argoproj.io/Application` requires ArgoCD CRDs.
- `external-secrets.io/ClusterSecretStore` and `ExternalSecret` require External Secrets CRDs.
- Services may be blocked if the AWS Load Balancer Controller webhook exists but has no ready endpoints.

The layer split prevents Terraform from planning CRD-backed resources before the controllers that install the CRDs are ready.

## Manual commands

```powershell
terraform -chdir=infra/terraform/environments/dev/aws init -reconfigure
terraform -chdir=infra/terraform/environments/dev/aws apply

aws eks update-kubeconfig --name practice-eks-dev --region us-east-1

terraform -chdir=infra/terraform/environments/dev/platform-core init -reconfigure
terraform -chdir=infra/terraform/environments/dev/platform-core apply
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=5m

terraform -chdir=infra/terraform/environments/dev/platform-services init -reconfigure
terraform -chdir=infra/terraform/environments/dev/platform-services apply
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=120s
kubectl wait --for=condition=Established crd/clustersecretstores.external-secrets.io --timeout=120s
kubectl wait --for=condition=Established crd/externalsecrets.external-secrets.io --timeout=120s

terraform -chdir=infra/terraform/environments/dev/platform-bootstrap init -reconfigure
terraform -chdir=infra/terraform/environments/dev/platform-bootstrap apply
```
