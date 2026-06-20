module "eks_foundation" {
  source = "../../modules/eks-foundation"

  name               = var.name
  region             = var.region
  environment        = var.environment
  kubernetes_version = var.kubernetes_version
  vpc_cidr           = var.vpc_cidr

  node_instance_types = var.node_instance_types
  node_min_size       = var.node_min_size
  node_desired_size   = var.node_desired_size
  node_max_size       = var.node_max_size
}
