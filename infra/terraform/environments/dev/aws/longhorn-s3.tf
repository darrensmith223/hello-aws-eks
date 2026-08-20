# Off-cluster backupstore for Longhorn. Longhorn's local NVMe replicas protect
# against an individual node loss, while this bucket protects against loss of
# the cluster/instance-store replica set itself.
resource "aws_s3_bucket" "longhorn_backups" {
  bucket        = var.longhorn_backup_bucket_name
  force_destroy = true # dev cluster: allow destroy.ps1 to remove backup objects

  tags = {
    Component = "longhorn-backups"
  }
}

resource "aws_s3_bucket_versioning" "longhorn_backups" {
  bucket = aws_s3_bucket.longhorn_backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "longhorn_backups" {
  bucket = aws_s3_bucket.longhorn_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "longhorn_backups" {
  bucket = aws_s3_bucket.longhorn_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Longhorn controls retention of current backups. Versioning is kept as an
# extra recovery guardrail, but stale non-current object versions are expired
# after 30 days so a dev cluster does not accumulate hidden S3 cost forever.
resource "aws_s3_bucket_lifecycle_configuration" "longhorn_backups" {
  bucket = aws_s3_bucket.longhorn_backups.id

  depends_on = [aws_s3_bucket_versioning.longhorn_backups]

  rule {
    id     = "expire-noncurrent-backup-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# Least-privilege S3 permissions used by Longhorn's backupstore client.
data "aws_iam_policy_document" "longhorn_backup" {
  statement {
    sid    = "BucketMetadata"
    effect = "Allow"

    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]

    resources = [aws_s3_bucket.longhorn_backups.arn]
  }

  statement {
    sid    = "BackupObjects"
    effect = "Allow"

    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
    ]

    resources = ["${aws_s3_bucket.longhorn_backups.arn}/*"]
  }
}

resource "aws_iam_policy" "longhorn_backup" {
  name   = "${var.name}-longhorn-backup"
  policy = data.aws_iam_policy_document.longhorn_backup.json

  tags = {
    Component = "longhorn-backups"
  }
}

# EKS Pod Identity avoids static AWS keys. deploy.ps1 writes this role ARN into
# Longhorn's credential Secret as AWS_IAM_ROLE_ARN, which Longhorn uses to allow
# ambient IAM credentials instead of requiring AWS_ACCESS_KEY_ID/
# AWS_SECRET_ACCESS_KEY. The cluster already has the eks-pod-identity-agent
# add-on enabled in eks-foundation.
data "aws_iam_policy_document" "longhorn_backup_assume_role" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "longhorn_backup" {
  name               = "${var.name}-longhorn-backup"
  assume_role_policy = data.aws_iam_policy_document.longhorn_backup_assume_role.json

  tags = {
    Component = "longhorn-backups"
  }
}

resource "aws_iam_role_policy_attachment" "longhorn_backup" {
  role       = aws_iam_role.longhorn_backup.name
  policy_arn = aws_iam_policy.longhorn_backup.arn
}

resource "aws_eks_pod_identity_association" "longhorn_backup" {
  cluster_name    = module.eks_foundation.cluster_name
  namespace       = "longhorn-system"
  service_account = "longhorn-service-account"
  role_arn        = aws_iam_role.longhorn_backup.arn
}
