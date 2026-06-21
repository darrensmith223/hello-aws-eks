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

data "aws_eks_cluster" "this" {
  name = module.eks_foundation.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks_foundation.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}