resource "kubernetes_namespace" "external_dns" {
  metadata {
    name = "external-dns"

    labels = {
      "app.kubernetes.io/name"       = "external-dns"
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }
}

resource "kubernetes_service_account" "external_dns" {
  metadata {
    name      = "external-dns"
    namespace = kubernetes_namespace.external_dns.metadata[0].name

    labels = {
      "app.kubernetes.io/name"       = "external-dns"
      "app.kubernetes.io/component"  = "controller"
      "app.kubernetes.io/managed-by" = "Terraform"
    }

    annotations = {
      "eks.amazonaws.com/role-arn" = local.aws_outputs.external_dns_role_arn
    }
  }
}

resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  namespace  = kubernetes_namespace.external_dns.metadata[0].name
  version    = var.external_dns_chart_version

  set {
    name  = "provider.name"
    value = "aws"
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.external_dns.metadata[0].name
  }

  set {
    name  = "txtOwnerId"
    value = local.aws_outputs.cluster_name
  }

  set {
    name  = "policy"
    value = "upsert-only"
  }

  set {
    name  = "extraArgs[0]"
    value = "--aws-zone-type=public"
  }

  set {
    name  = "extraArgs[1]"
    value = "--domain-filter=${var.domain_name}"
  }

  depends_on = [
    kubernetes_service_account.external_dns
  ]
}