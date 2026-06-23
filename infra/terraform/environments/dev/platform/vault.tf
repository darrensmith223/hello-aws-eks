resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"
  }
}

resource "kubernetes_service_account" "vault" {
  metadata {
    name      = "vault"
    namespace = kubernetes_namespace.vault.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = local.aws_outputs.vault_role_arn
    }
  }
}
