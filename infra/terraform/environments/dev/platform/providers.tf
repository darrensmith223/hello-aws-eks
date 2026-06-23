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
  name = local.aws_outputs.cluster_name
}

# Uses exec-based auth so the token is fetched fresh on every API call,
# avoiding the 15-minute expiry issue with data.aws_eks_cluster_auth.
provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.aws_outputs.cluster_name, "--region", var.region, "--profile", "terraform"]
  }
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.aws_outputs.cluster_name, "--region", var.region, "--profile", "terraform"]
    }
  }
}
