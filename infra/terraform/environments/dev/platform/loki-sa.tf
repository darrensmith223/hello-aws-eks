# Loki's service account is pre-created here so the IRSA annotation is in place
# before ArgoCD deploys the Loki Helm chart. ArgoCD manages the Helm release
# itself (infra/k8s/platform/observability/loki.yaml); Terraform only owns the
# namespace and service account.
resource "kubernetes_namespace" "logging" {
  metadata {
    name = "logging"
  }
}

resource "kubernetes_service_account" "loki" {
  metadata {
    name      = "loki"
    namespace = kubernetes_namespace.logging.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = local.aws_outputs.loki_role_arn
    }
  }
}
