resource "aws_kms_key" "vault_unseal" {
  description             = "KMS key for Vault auto-unseal in ${var.name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Component = "vault"
  }
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/${var.name}-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}

resource "aws_iam_policy" "vault_unseal" {
  name = "${var.name}-vault-unseal"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.vault_unseal.arn
      }
    ]
  })
}

module "vault_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.name}-vault"

  role_policy_arns = {
    vault_unseal = aws_iam_policy.vault_unseal.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks_foundation.oidc_provider_arn
      namespace_service_accounts = ["vault:vault"]
    }
  }

  tags = {
    Component = "vault"
  }
}
