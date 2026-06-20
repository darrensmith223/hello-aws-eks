provider "aws" {
  region = var.region
  profile = "terraform-prod"

  default_tags {
    tags = {
      Project     = var.name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
