# S3 bucket for Loki log storage. Using S3 instead of the default
# filesystem backend means logs survive pod restarts and allows future
# scale-out to multiple Loki replicas.
resource "aws_s3_bucket" "loki" {
  bucket = "${var.name}-loki-logs"

  tags = {
    Component = "loki"
  }
}

resource "aws_s3_bucket_versioning" "loki" {
  bucket = aws_s3_bucket.loki.id

  versioning_configuration {
    status = "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket = aws_s3_bucket.loki.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    expiration {
      # Retain logs for 30 days; adjust for your compliance requirements.
      days = 30
    }
  }
}

# IAM policy granting Loki read/write access to its S3 bucket.
resource "aws_iam_policy" "loki" {
  name = "${var.name}-loki"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.loki.arn,
          "${aws_s3_bucket.loki.arn}/*",
        ]
      }
    ]
  })
}

module "loki_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.name}-loki"

  role_policy_arns = {
    loki = aws_iam_policy.loki.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks_foundation.oidc_provider_arn
      namespace_service_accounts = ["logging:loki"]
    }
  }

  tags = {
    Component = "loki"
  }
}
