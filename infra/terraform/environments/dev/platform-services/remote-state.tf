data "terraform_remote_state" "aws" {
  backend = "s3"

  config = {
    bucket  = "practice-eks-dev-terraform-state-dds-20260619"
    key     = "eks/dev/aws/terraform.tfstate"
    region  = "us-east-1"
    profile = "terraform"
  }
}

locals {
  aws_outputs = data.terraform_remote_state.aws.outputs
  hostnames   = local.aws_outputs.hostnames
}
