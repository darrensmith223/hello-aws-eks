# Shared backend configuration for the dev environment.
# Pass at init time for every stack under environments/dev/:
#
#   terraform init -backend-config=../backend.hcl
#
# Each stack's backend.tf only specifies the unique `key` for that stack.

bucket         = "practice-eks-dev-terraform-state-dds-20260619"
region         = "us-east-1"
dynamodb_table = "practice-eks-dev-terraform-locks"
encrypt        = true
profile        = "terraform"
