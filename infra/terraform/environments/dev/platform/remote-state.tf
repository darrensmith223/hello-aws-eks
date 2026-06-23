# Remote state is read using the same backend coordinates as this stack's own
# backend, which means the bucket name is sourced from backend.hcl at init
# time — not hardcoded here. Keeping the config consistent means a rename only
# needs to happen in one place: backend.hcl.
data "terraform_remote_state" "aws" {
  backend = "s3"

  config = {
    bucket  = var.state_bucket
    key     = "eks/dev/aws/terraform.tfstate"
    region  = var.region
    profile = "terraform"
  }
}

locals {
  aws_outputs = data.terraform_remote_state.aws.outputs
  hostnames   = local.aws_outputs.hostnames
}
