data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  tags = merge(
    {
      Project     = var.name
      Environment = var.environment
      ManagedBy   = "Terraform"
    },
    var.tags
  )
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, az in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, az in local.azs : cidrsubnet(var.vpc_cidr, 4, k + 8)]

  enable_nat_gateway = true
  # single_nat_gateway saves cost in dev/test but creates a single point of
  # failure: if the NAT gateway's AZ goes down, all private subnets lose
  # outbound connectivity. Set to false (one NAT per AZ) for staging/prod.
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

resource "aws_iam_role" "ebs_csi_driver" {
  name = "${var.name}-ebs-csi-driver"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access  = true
  endpoint_private_access = true

  # API-only mode: access is managed exclusively via EKS access entries,
  # which are auditable and fully Terraform-managed. The aws-auth ConfigMap
  # is no longer used or required.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  node_security_group_additional_rules = {
    egress_all = {
      description = "Allow all node outbound traffic"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  addons = {
    vpc-cni = {
      # Pinned versions prevent unexpected changes on `terraform apply`.
      # Update these intentionally when upgrading the cluster.
      # To find the latest: aws eks describe-addon-versions --kubernetes-version 1.32 --addon-name vpc-cni
      addon_version  = "v1.19.2-eksbuild.5"
      before_compute = true
    }

    kube-proxy = {
      addon_version = "v1.32.3-eksbuild.2"
    }

    coredns = {
      addon_version = "v1.11.4-eksbuild.2"
    }

    aws-ebs-csi-driver = {
      addon_version = "v1.41.0-eksbuild.1"

      pod_identity_association = [
        {
          service_account = "ebs-csi-controller-sa"
          role_arn        = aws_iam_role.ebs_csi_driver.arn
        }
      ]
    }

    eks-pod-identity-agent = {
      addon_version = "v1.3.4-eksbuild.1"
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      name = "default"

      ami_type = "AL2023_x86_64_STANDARD"

      instance_types             = var.node_instance_types
      use_custom_launch_template = false

      min_size     = var.node_min_size
      desired_size = var.node_desired_size
      max_size     = var.node_max_size

      disk_size = 50

      labels = {
        workload = "general"
      }

      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    }
  }

  tags = local.tags

  enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]
}
