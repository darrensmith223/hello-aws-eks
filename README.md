# EKS Migration Starter

This repo provisions a production-ready AWS EKS cluster using a two-stack Terraform architecture, GitOps via ArgoCD, and a full observability and secrets platform.

**What it creates:**

- VPC with public/private subnets and NAT gateway (single NAT — dev only)
- EKS cluster with managed node group (API-only auth mode)
- Core EKS add-ons: vpc-cni, kube-proxy, coredns, aws-ebs-csi-driver, eks-pod-identity-agent
- IRSA/OIDC for all workloads requiring AWS API access
- AWS Load Balancer Controller + ExternalDNS
- ArgoCD (HTTPS via ACM + Route53)
- External Secrets Operator (backed by AWS Secrets Manager)
- Vault with KMS auto-unseal and Raft HA storage
- Grafana + Loki (S3-backed) + Alloy log collector
- LDAP (389ds) with persistent storage

---

## Architecture

Two Terraform stacks replace the previous five-stack layout:

```
bootstrap     →  S3 state bucket + DynamoDB lock table
aws           →  VPC, EKS, IRSA roles, ACM cert, Route53 zone, Loki S3 bucket
platform      →  All Kubernetes resources (namespaces, service accounts,
                 Helm releases, ArgoCD Applications, DNS record)
```

The `platform` stack reads the `aws` stack's outputs via remote state and manages everything Kubernetes-side in one apply. This removes the sequencing overhead of the previous four separate K8s stacks while keeping the AWS and Kubernetes blast radii cleanly separated.

---

## Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) configured with a `terraform` profile
- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.8.0
- `kubectl` installed
- `helm` installed

---

## First-time setup

### 1. Store the Git repo credential

ArgoCD uses a credential stored in AWS Secrets Manager to pull this repo. Run this once before deploying:

```powershell
.\scripts\create-repo-keys.ps1
```

This stores a `username` + `password` (personal access token) at `dev/argocd/repo/hello-aws-eks` in AWS Secrets Manager. The deploy script reads this secret and injects it as a Kubernetes Secret — no ExternalSecret chicken-and-egg problem.

### 2. Deploy

```powershell
.\deploy.ps1
```

This runs all three stacks in order. To plan without applying:

```powershell
.\deploy.ps1 -PlanOnly
```

### 3. Validate

```powershell
.\scripts\validate-deploy.ps1
```

---

## Manual deployment

All stacks share a single `backend.hcl`:

```bash
# bootstrap (run once)
cd infra/terraform/bootstrap
terraform init
terraform apply

# aws stack
cd ../environments/dev/aws
terraform init -backend-config=../backend.hcl
terraform apply

# platform stack
cd ../platform
terraform init -backend-config=../backend.hcl
terraform apply -var "state_bucket=<your-bucket-name>"
```

---

## Scripts

| Script | Purpose |
|--------|---------|
| `.\deploy.ps1` | Apply all stacks in order |
| `.\deploy.ps1 -PlanOnly` | Plan only (stops after aws plan) |
| `.\deploy.ps1 -SkipBootstrap` | Skip bootstrap stack (already applied) |
| `.\destroy.ps1` | Destroy all stacks in reverse order |
| `.\scripts\create-repo-keys.ps1` | Store GitHub credentials in AWS Secrets Manager |
| `.\scripts\validate-deploy.ps1` | Validate a successful deployment |
| `.\scripts\validate-destroy.ps1` | Validate a clean destroy |

---

## Configure kubectl

```bash
aws eks update-kubeconfig --region us-east-1 --name practice-eks-dev --profile terraform
kubectl get nodes
kubectl get pods -A
kubectl get storageclass
```

---

## Key design decisions

**EKS auth mode: API only.** The cluster uses `authentication_mode = "API"` (EKS access entries) rather than `API_AND_CONFIG_MAP`. Access entries are Terraform-managed, auditable, and don't require ConfigMap manipulation. See the [AWS docs](https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html) for migration guidance if coming from an existing cluster.

**gp3 as sole default StorageClass.** EKS ships with `gp2` marked as default. This repo creates `gp3` as the default and patches `gp2` to remove its default annotation, preventing the ambiguous-PVC-binding failure that occurs when two defaults exist.

**Loki S3 backend.** Loki uses an S3 bucket (provisioned in the `aws` stack) instead of the default filesystem backend. Logs survive pod restarts and the setup can scale to multiple replicas. A 30-day lifecycle rule keeps storage costs in check for dev.

**ArgoCD repo secret via direct Kubernetes Secret.** The repo credential is read from AWS Secrets Manager at `terraform apply` time and written as a plain Kubernetes Secret. This avoids the previous ExternalSecret approach, which required ArgoCD to already be syncing before it could read its own repo credential.

**Single `platform` stack.** The previous four Kubernetes stacks (`platform-core`, `platform-services`, `platform-bootstrap`, `platform-dns`) are merged into one. Ordering within the stack is handled by Terraform `depends_on` chains, not by separate `terraform apply` invocations.

**No hardcoded bucket names in scripts.** The deploy and destroy scripts parse the bucket name from `backend.hcl` at runtime. The only place the bucket name lives is `backend.hcl` and `terraform.tfvars`.

**Single NAT gateway (dev only).** Saves cost in dev but is a single point of failure. Set `single_nat_gateway = false` in `modules/eks-foundation/main.tf` for staging/prod.

**EKS addon versions are pinned.** Update them intentionally when upgrading the cluster. Find latest versions with:

```bash
aws eks describe-addon-versions --kubernetes-version 1.32 --addon-name <name>
```
