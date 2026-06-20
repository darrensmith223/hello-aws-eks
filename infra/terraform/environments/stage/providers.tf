provider "aws" {
  region = var.region
  profile = "terraform-stage"

  default_tags {
    tags = {
      Project     = var.name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
