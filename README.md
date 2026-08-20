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
- Prometheus + Alertmanager + kube-state-metrics + node-exporter
- Grafana + Loki (S3-backed) + Alloy log collector
- Longhorn distributed storage on local NVMe with S3 off-cluster backups
- LDAP (389ds) with persistent storage

---

## Architecture

Two Terraform stacks replace the previous five-stack layout:

```
bootstrap     →  S3 state bucket + DynamoDB lock table
aws           →  VPC, EKS, IAM workload roles, ACM cert, Route53 zone, Loki + Longhorn S3 buckets
platform      →  All Kubernetes resources (namespaces, service accounts,
                 Helm releases, ArgoCD Applications, DNS record)
```

The `platform` stack reads the `aws` stack's outputs via remote state and manages everything Kubernetes-side in one apply.

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

This runs all three stacks in order.

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

| Script                            | Purpose                                           |
|--------                           |---------                                          |
| `.\deploy.ps1`                    | Apply all stacks in order                         |
| `.\destroy.ps1`                   | Destroy all stacks in reverse order               |
| `.\scripts\create-repo-keys.ps1`  | Store GitHub credentials in AWS Secrets Manager   |
| `.\scripts\validate-deploy.ps1`   | Validate a successful deployment                  |
| `.\scripts\validate-destroy.ps1`  | Validate a clean destroy                          |

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

**Longhorn storage and backups.** Longhorn remains an opt-in StorageClass; `gp3` stays the sole default. Longhorn replicas use the c6gd local NVMe mounted at `/var/lib/longhorn`, while off-cluster backups use S3. The dev backup bucket is configured by `longhorn_backup_bucket_name` in `infra/terraform/environments/dev/aws/terraform.tfvars` and defaults to `dev-longhorn-backups`. Longhorn receives S3 permissions through EKS Pod Identity rather than static AWS keys. `deploy.ps1` configures a `daily-backup` recurring job at 03:00 UTC, retains seven backups per volume, and performs a periodic full backup after seven incremental backups.

**Prometheus monitoring.** `kube-prometheus-stack` installs Prometheus Operator, Prometheus, Alertmanager, node-exporter, and kube-state-metrics. Its bundled Grafana is disabled; the existing Grafana instance uses Prometheus as its default datasource and Loki as its logs datasource. Longhorn exposes a ServiceMonitor so its storage metrics are collected automatically. Prometheus persistence remains on `gp3` so a Longhorn storage incident does not also remove the metrics needed to diagnose it.

**ArgoCD repo secret via direct Kubernetes Secret.** The repo credential is read from AWS Secrets Manager at `terraform apply` time and written as a plain Kubernetes Secret. This avoids the previous ExternalSecret approach, which required ArgoCD to already be syncing before it could read its own repo credential.

**Single `platform` stack.** The previous four Kubernetes stacks (`platform-core`, `platform-services`, `platform-bootstrap`, `platform-dns`) are merged into one. Ordering within the stack is handled by Terraform `depends_on` chains, not by separate `terraform apply` invocations.

**No hardcoded bucket names in scripts.** The deploy and destroy scripts parse the bucket name from `backend.hcl` at runtime. The only place the bucket name lives is `backend.hcl` and `terraform.tfvars`.

**Single NAT gateway (dev only).** Saves cost in dev but is a single point of failure. Set `single_nat_gateway = false` in `modules/eks-foundation/main.tf` for staging/prod.

**EKS addon versions are pinned.** Update them intentionally when upgrading the cluster. Find latest versions with:

```bash
aws eks describe-addon-versions --kubernetes-version 1.32 --addon-name <name>
```
