terraform {
  backend "s3" {
    bucket         = "practice-eks-dev-terraform-state-dds-20260619"
    key            = "eks/dev/platform-bootstrap/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "practice-eks-dev-terraform-locks"
    encrypt        = true
    profile        = "terraform"
  }
}
