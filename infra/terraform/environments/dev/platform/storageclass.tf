# Set gp3 as the cluster default StorageClass.
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type   = "gp3"
    fsType = "ext4"
  }
}

# EKS ships with gp2 marked as the default StorageClass. Having two defaults
# causes ambiguous PVC binding — Kubernetes will refuse to pick one and leave
# PVCs pending. Patching gp2 here ensures gp3 is the sole default.
resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"

  metadata {
    name = "gp2"
  }

  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  # force = true is required because gp2 is not managed by Terraform;
  # without it the provider refuses to annotate a resource it doesn't own.
  force = true

  depends_on = [kubernetes_storage_class.gp3]
}
