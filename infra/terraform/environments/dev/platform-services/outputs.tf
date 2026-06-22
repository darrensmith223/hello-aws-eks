output "cluster_name" {
  value = local.aws_outputs.cluster_name
}

output "argocd_namespace" {
  value = kubernetes_namespace.argocd.metadata[0].name
}

output "external_secrets_namespace" {
  value = kubernetes_namespace.external_secrets.metadata[0].name
}
