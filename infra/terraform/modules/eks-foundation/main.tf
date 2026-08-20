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

    ingress_rancher_imperative_api = {
      description                   = "Cluster API to Rancher imperative API"
      protocol                      = "tcp"
      from_port                     = 6666
      to_port                       = 6666
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  addons = {
    vpc-cni = {
      # Pinned versions prevent unexpected changes on `terraform apply`.
      # Update these intentionally when upgrading the cluster.
      #
      # NOTE: these version strings were selected as reasonable candidates
      # for Kubernetes 1.34 but were NOT verified against the live EKS
      # addon-versions API (this environment has no AWS credentials/network
      # access). Before applying, confirm each with:
      #   aws eks describe-addon-versions --kubernetes-version 1.34 --addon-name <name>
      # and also confirm arm64 build availability for the c6gd (Graviton)
      # node group -- all of these addons ship multi-arch images, but it's
      # worth a quick confirmation on the specific build tag you pin.
      addon_version  = "v1.20.4-eksbuild.1"
      before_compute = true
    }

    kube-proxy = {
      addon_version = "v1.34.0-eksbuild.2"
    }

    coredns = {
      addon_version = "v1.12.1-eksbuild.2"
    }

    aws-ebs-csi-driver = {
      addon_version = "v1.51.0-eksbuild.1"

      pod_identity_association = [
        {
          service_account = "ebs-csi-controller-sa"
          role_arn        = aws_iam_role.ebs_csi_driver.arn
        }
      ]
    }

    eks-pod-identity-agent = {
      addon_version = "v1.3.9-eksbuild.3"
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      name = "default"

      # c6gd is a Graviton (arm64) family, so this must be an ARM AMI type.
      ami_type = "AL2023_ARM_64_STANDARD"

      instance_types             = var.node_instance_types
      use_custom_launch_template = true

      # c6gd nodes ship with local NVMe instance storage (237 GB on
      # .xlarge) that's already included in the instance price and
      # substantially faster than gp3 (baseline 6,000 IOPS / 1,188 Mbps vs
      # gp3's 3,000 IOPS / 125 MB/s). Longhorn's data is mounted there
      # instead of a separate EBS volume.
      #
      # IMPORTANT: instance store is ephemeral. Data is wiped on stop,
      # hibernation, or termination -- including ASG scale-in/out and
      # rolling node replacement -- though it DOES survive a plain reboot.
      # This is acceptable because Longhorn's own replication (2 replicas
      # per volume, spread across nodes) is the actual durability
      # mechanism here, not the underlying disk. No block_device_mappings
      # entry is needed for it: AWS auto-attaches all supported instance
      # store volumes at launch for instance types that have them.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      cloudinit_pre_nodeadm = [
        {
          content_type = "text/x-shellscript"
          content      = <<-EOT
          #!/bin/bash
          set -euxo pipefail

          # iscsi: required by Longhorn's V1 data engine.
          # nfs-utils: required only if/when Longhorn RWX volumes are used.
          dnf install -y iscsi-initiator-utils nfs-utils

          # Longhorn V1 requires the iscsi_tcp kernel module to be loaded
          # before iscsid starts. Persist it so the ordering survives reboots.
          echo iscsi_tcp > /etc/modules-load.d/longhorn.conf
          modprobe iscsi_tcp
          systemctl enable --now iscsid

          iscsiadm --version
          systemctl is-active iscsid
          lsmod | grep -q '^iscsi_tcp'

          # --- Local NVMe instance store for Longhorn data ---
          # Distinguish the instance-store NVMe device from the root EBS
          # volume (also NVMe-backed on Nitro instances) by its model
          # string in sysfs, rather than assuming a device name/order.
          DEVICE=""
          for attempt in 1 2 3 4 5 6 7 8 9 10; do
            for ctrl in /sys/class/nvme/nvme*; do
              [ -e "$ctrl/model" ] || continue
              if grep -q "Instance Storage" "$ctrl/model"; then
                ctrl_name=$(basename "$ctrl")
                candidate="/dev/$${ctrl_name}n1"
                if [ -b "$candidate" ]; then
                  DEVICE="$candidate"
                  break 2
                fi
              fi
            done
            sleep 3
          done

          if [ -z "$DEVICE" ]; then
            echo "ERROR: no NVMe instance store device found; Longhorn data volume not available." >&2
            exit 1
          fi

          MOUNT_POINT=/var/lib/longhorn
          mkdir -p "$MOUNT_POINT"

          # Only format if there's no filesystem yet. Instance store data
          # survives a plain reboot (just not a stop/terminate), so don't
          # blindly reformat on every boot.
          if ! blkid "$DEVICE" >/dev/null 2>&1; then
            mkfs.ext4 -F "$DEVICE"
          fi

          if ! grep -q "$MOUNT_POINT" /etc/fstab; then
            # nofail is required here: instance store devices are not
            # guaranteed to enumerate at the exact same path across every
            # boot, and a missing device must not block node boot.
            VOL_UUID=$(blkid -s UUID -o value "$DEVICE")
            echo "UUID=$VOL_UUID  $MOUNT_POINT  ext4  defaults,nofail  0  2" >> /etc/fstab
          fi

          mount -a
        EOT
        }
      ]

      min_size     = var.node_min_size
      desired_size = var.node_desired_size
      max_size     = var.node_max_size

      labels = {
        workload         = "general"
        "longhorn-ready" = "true"
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
