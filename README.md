# EKS Migration Starter

This is the first IaC milestone for migrating the local Kubernetes environment to AWS EKS.

It creates the foundation:

- VPC
- public/private subnets
- NAT gateway
- EKS cluster
- default managed node group
- core EKS add-ons
- EBS CSI add-on
- IRSA/OIDC support
- ALB ingress
- Route53
- cert-manager
- ArgoCD
- Secrets management (AWS Secrets Manager)

It intentionally does not install Vault, LDAP, monitoring, logging, or application workloads yet.

## Usage

```bash
cd infra/terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

Then configure kubectl:

```bash
aws eks update-kubeconfig --region us-east-1 --name practice-eks-dev
kubectl get nodes
kubectl get pods -A
kubectl get storageclass
```

Destroy test:

```bash
terraform destroy
```

# Configuring AWS

* Download AWS CLI
* Configure AWS CLI with `aws configure`

# Deploy
Run `.\deploy.ps1` (`.\deploy.ps1 -PlanOnly` for the plan only)

Be prepared to enter:
* AWS token ID
* AWS access token

## Prerequisites



# Destroy
Run `.\destroy.ps1`