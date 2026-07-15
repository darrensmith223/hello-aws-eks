param(
    [string]$Region = "us-east-1",
    [string]$Profile = "terraform",
    [string]$ClusterName = "practice-eks-dev",
    [string]$DomainName = "ddsprojects.link",
    [string]$RepoSecretName = "dev/argocd/repo/hello-aws-eks"
)

$ErrorActionPreference = "Continue"
$failed = 0

function Test-Step {
    param(
        [string]$Name,
        [scriptblock]$Command
    )

    Write-Host "`n[CHECK] $Name" -ForegroundColor Cyan

    try {
        & $Command
        if ($LASTEXITCODE -ne 0) { throw "Command failed" }
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    catch {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)"
        $script:failed++
    }
}

Test-Step "EKS cluster exists" {
    aws eks describe-cluster `
        --name $ClusterName `
        --region $Region `
        --profile $Profile `
        --query "cluster.status" `
        --output text
}

Test-Step "kubectl can reach cluster" {
    kubectl get nodes
}

Test-Step "External Secrets pods running" {
    kubectl get pods -n external-secrets
}

Test-Step "External Secrets service account has IRSA annotation" {
    kubectl get sa external-secrets -n external-secrets `
        -o jsonpath="{.metadata.annotations.eks\.amazonaws\.com/role-arn}"
}

Test-Step "AWS Secrets Manager repo secret exists" {
    aws secretsmanager describe-secret `
        --secret-id $RepoSecretName `
        --region $Region `
        --profile $Profile `
        --query "Name" `
        --output text
}

Test-Step "ClusterSecretStore exists and is ready" {
    kubectl get clustersecretstore aws-secrets-manager
}

Test-Step "ArgoCD pods running" {
    kubectl get pods -n argocd
}

Test-Step "ArgoCD repo secret exists" {
    kubectl get secret hello-aws-eks-repo -n argocd
}

Test-Step "ArgoCD platform-root app is synced/healthy" {
    kubectl get application platform-root -n argocd
}


Test-Step "Vault namespace exists" {
    kubectl get namespace vault
}

Test-Step "Vault service account has IRSA annotation" {
    kubectl get sa vault -n vault `
        -o jsonpath="{.metadata.annotations.eks\.amazonaws\.com/role-arn}"
}

Test-Step "Vault KMS alias exists" {
    aws kms describe-key `
        --key-id alias/$ClusterName-vault-unseal `
        --region $Region `
        --profile $Profile `
        --query "KeyMetadata.KeyState" `
        --output text
}

Test-Step "Vault ArgoCD app exists" {
    kubectl get application vault -n argocd
}

Test-Step "Vault pods exist" {
    kubectl get pods -n vault
}

Test-Step "AWS Load Balancer Controller running" {
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
}

Test-Step "Rancher ArgoCD app exists" {
    kubectl get application rancher -n argocd
}

Test-Step "Rancher rollout is available" {
    kubectl rollout status deployment/rancher -n cattle-system --timeout=10m
}

Test-Step "Rancher hostname resolves" {
    nslookup "rancher.$DomainName"
}

Test-Step "Longhorn ArgoCD app exists" {
    kubectl get application longhorn -n argocd
}

Test-Step "Longhorn manager DaemonSet is available" {
    kubectl rollout status daemonset/longhorn-manager -n longhorn-system --timeout=10m
}

Test-Step "Longhorn StorageClass exists and gp3 remains default" {
    kubectl get storageclass longhorn
    $defaultClass = kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}'
    if (($defaultClass | Out-String).Trim() -ne "gp3") {
        throw "Expected gp3 to be the sole default StorageClass, got: $defaultClass"
    }
}

Test-Step "ArgoCD hostname resolves" {
    nslookup "argocd.$DomainName"
}

if ($failed -eq 0) {
    Write-Host "`nDeployment validation PASSED." -ForegroundColor Green
    exit 0
}
else {
    Write-Host "`nDeployment validation FAILED with $failed issue(s)." -ForegroundColor Red
    exit 1
}