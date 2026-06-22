locals {
  hostnames = {
    argocd  = "argocd.${var.domain_name}"
    grafana = "grafana.${var.domain_name}"
    ldap    = "ldap.${var.domain_name}"
    hello   = "hello.${var.domain_name}"
  }
}
