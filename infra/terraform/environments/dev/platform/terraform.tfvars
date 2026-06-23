region          = "us-east-1"
environment     = "dev"
name            = "practice-eks-dev"
domain_name     = "ddsprojects.link"
gitops_repo_url = "https://github.com/darrensmith223/hello-aws-eks"

# Must match the bucket value in backend.hcl — used only for cross-stack
# remote state reads, not for this stack's own backend configuration.
state_bucket = "practice-eks-dev-terraform-state-dds-20260619"

aws_load_balancer_controller_chart_version = "1.14.0"
external_dns_chart_version                 = "1.21.1"
argocd_chart_version                       = "7.8.26"
external_secrets_chart_version             = "0.14.4"
