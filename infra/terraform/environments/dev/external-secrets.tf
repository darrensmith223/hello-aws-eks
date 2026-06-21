resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}

data "aws_caller_identity" "current" {}

resource "aws_iam_policy" "external_secrets" {
  name = "${var.name}-external-secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]

      Resource = [
        "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.environment}/*"
      ]
    }]
  })
}

module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.name}-external-secrets"

  role_policy_arns = {
    external_secrets = aws_iam_policy.external_secrets.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks_foundation.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

resource "kubernetes_service_account" "external_secrets" {
  metadata {
    name      = "external-secrets"
    namespace = kubernetes_namespace.external_secrets.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = module.external_secrets_irsa.iam_role_arn
    }
  }
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  namespace  = kubernetes_namespace.external_secrets.metadata[0].name

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.external_secrets.metadata[0].name
  }

  depends_on = [
    kubernetes_namespace.external_secrets,
    kubernetes_service_account.external_secrets
  ]
}