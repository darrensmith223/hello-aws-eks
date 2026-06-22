# EKS Migration Starter

This is the first IaC milestone for migrating a local Kubernetes environment to AWS EKS.

It creates the foundation:

- VPC with public/private subnets and NAT gateway (single NAT — dev only)
- EKS cluster with managed node group
- Core EKS add-ons (vpc-cni, kube-proxy, coredns, ebs-csi, pod-identity-agent)
- IRSA/OIDC support
- AWS Load Balancer Controller
- ArgoCD (with HTTPS via ACM + Route53)
- External Secrets Operator (backed by AWS Secrets Manager)

It intentionally does **not** install cert-manager, Vault, LDAP, monitoring, logging, or application workloads yet.

---

## Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) configured with a `terraform` profile
- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.8.0
- `kubectl` installed

---

## Deployment Order

There are five Terraform stacks. They must be applied in order since later stacks read remote state from earlier ones.

```
1. bootstrap          (S3 state bucket + DynamoDB lock table)
2. environments/dev/aws              (VPC + EKS cluster + IRSA roles + ACM cert)
3. environments/dev/platform-services  (ArgoCD + External Secrets helm installs)
4. environments/dev/platform-core      (AWS Load Balancer Controller)
5. environments/dev/platform-bootstrap (ArgoCD Application CRs + repo secret)
6. environments/dev/platform-dns       (Route53 CNAME → ALB)
```

### Shared backend config

All dev stacks share a single `backend.hcl` to avoid repeating the bucket name in every file.
Pass it at `init` time:

```bash
cd infra/terraform/environments/dev/aws
terraform init -backend-config=../backend.hcl
terraform plan
terraform apply
```

Repeat for each stack in the order above, adjusting the directory name.

---

## PowerShell scripts

| Script | Purpose |
|--------|---------|
| `.\deploy.ps1` | Applies all stacks in order |
| `.\deploy.ps1 -PlanOnly` | Plan only |
| `.\destroy.ps1` | Destroys all stacks in reverse order |
| `.\scripts\create-repo-keys.ps1` | Creates GitHub repo credentials in AWS Secrets Manager |
| `.\scripts\validate-deploy.ps1` | Validates a successful deployment |
| `.\scripts\validate-destroy.ps1` | Validates a clean destroy |

---

## Configure kubectl

```bash
aws eks update-kubeconfig --region us-east-1 --name practice-eks-dev --profile terraform
kubectl get nodes
kubectl get pods -A
kubectl get storageclass
```

---

## Notes

- **Single NAT gateway**: costs less in dev but is a single point of failure. Set `single_nat_gateway = false` in `modules/eks-foundation/main.tf` for staging/prod.
- **EKS addon versions**: pinned explicitly in the module. Update them intentionally when upgrading the cluster. Find latest versions with `aws eks describe-addon-versions --kubernetes-version <version> --addon-name <name>`.
- **ClusterSecretStore**: managed solely by ArgoCD via `infra/k8s/platform/cluster-secret-store.yaml`. Do not recreate it in Terraform.
