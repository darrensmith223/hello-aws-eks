# Run: terraform init -backend-config=../backend.hcl
terraform {
  backend "s3" {
    key = "eks/dev/platform-dns/terraform.tfstate"
  }
}
