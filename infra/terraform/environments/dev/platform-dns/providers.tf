provider "aws" {
  region  = var.region
  profile = "terraform"

  default_tags {
    tags = {
      Project     = var.name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
