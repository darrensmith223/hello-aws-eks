param(
    [string]$Environment = "dev",
    [switch]$PlanOnly,
    [switch]$SkipBootstrap,
    [switch]$SkipKubeconfig
)

$ErrorActionPreference = "Stop"

function Require-Command($Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Run-Step($Message, [scriptblock]$ScriptBlock) {
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
    & $ScriptBlock
    if ($LASTEXITCODE -ne 0) {
        throw "Step failed: $Message"
    }
}

function Run-AllowFailure([scriptblock]$ScriptBlock) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $ScriptBlock 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    return @{ Output = $output; ExitCode = $exitCode }
}

function Wait-Until($Description, [scriptblock]$Check, $TimeoutSeconds = 600, $SleepSeconds = 15) {
    Write-Host ""
    Write-Host "=== Waiting for $Description ===" -ForegroundColor Cyan
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if (& $Check) {
            Write-Host "$Description complete."
            return
        }
        Start-Sleep -Seconds $SleepSeconds
        $elapsed += $SleepSeconds
        Write-Host "Still waiting for $Description... ${elapsed}s elapsed"
    }
    throw "Timed out waiting for $Description"
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

$BootstrapDir = "infra/terraform/bootstrap"
$AwsDir = "infra/terraform/environments/$Environment/aws"
$CoreDir = "infra/terraform/environments/$Environment/platform-core"
$ServicesDir = "infra/terraform/environments/$Environment/platform-services"
$BootstrapPlatformDir = "infra/terraform/environments/$Environment/platform-bootstrap"
$DnsDir = "infra/terraform/environments/$Environment/platform-dns"

Require-Command terraform
Require-Command aws
if (-not $SkipKubeconfig) {
    Require-Command kubectl
}

foreach ($dir in @($BootstrapDir, $AwsDir, $CoreDir, $ServicesDir, $BootstrapPlatformDir, $DnsDir)) {
    if (-not (Test-Path $dir)) {
        throw "Required directory not found: $dir"
    }
}

Run-Step "Checking AWS identity" {
    aws sts get-caller-identity
}

if (-not $SkipBootstrap) {
    Run-Step "Terraform init - bootstrap" {
        terraform "-chdir=$BootstrapDir" init
    }

    if ($PlanOnly) {
        Run-Step "Terraform plan - bootstrap" {
            terraform "-chdir=$BootstrapDir" plan
        }
    }
    else {
        Write-Host ""
        Write-Host "=== Terraform apply - bootstrap ===" -ForegroundColor Cyan
        $bootstrapApply = Run-AllowFailure {
            terraform "-chdir=$BootstrapDir" apply -auto-approve
        }

        if ($bootstrapApply.ExitCode -ne 0) {
            Write-Host "Bootstrap apply failed. Attempting to import existing bootstrap resources..." -ForegroundColor Yellow
            Run-AllowFailure { terraform "-chdir=$BootstrapDir" import aws_s3_bucket.terraform_state "practice-eks-dev-terraform-state-dds-20260619" } | Out-Null
            Run-AllowFailure { terraform "-chdir=$BootstrapDir" import aws_dynamodb_table.terraform_locks "practice-eks-dev-terraform-locks" } | Out-Null
            Run-Step "Retrying Terraform apply - bootstrap" {
                terraform "-chdir=$BootstrapDir" apply -auto-approve
            }
        }
    }
}

foreach ($layer in @(
    @{ Name = "AWS"; Path = $AwsDir },
    @{ Name = "platform-core"; Path = $CoreDir },
    @{ Name = "platform-services"; Path = $ServicesDir },
    @{ Name = "platform-bootstrap"; Path = $BootstrapPlatformDir },
    @{ Name = "platform-dns"; Path = $DnsDir }
)) {
    Run-Step "Terraform init - $($layer.Name)" {
        terraform "-chdir=$($layer.Path)" init -reconfigure -backend-config="backend.hcl"
    }
}

if ($PlanOnly) {
    Run-Step "Terraform plan - AWS layer" { terraform "-chdir=$AwsDir" plan }
    Write-Host ""
    Write-Host "PlanOnly stops after the AWS plan because Kubernetes CRD/webhook-dependent plans require the cluster and platform layers to be applied in order." -ForegroundColor Yellow
    exit 0
}

Run-Step "Terraform apply - AWS layer" {
    terraform "-chdir=$AwsDir" apply -auto-approve
}

$clusterName = terraform "-chdir=$AwsDir" output -raw cluster_name
$region = terraform "-chdir=$AwsDir" output -raw aws_region

if (-not $SkipKubeconfig) {
    Run-Step "Updating kubeconfig" {
        aws eks update-kubeconfig `
            --region $region `
            --name $clusterName
    }

    Run-Step "Verifying EKS nodes" {
        kubectl get nodes
    }
}

Run-Step "Terraform apply - platform-core" {
    terraform "-chdir=$CoreDir" apply -auto-approve
}

if (-not $SkipKubeconfig) {
    Run-Step "Waiting for AWS Load Balancer Controller rollout" {
        kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=5m
    }

    Wait-Until "AWS Load Balancer Controller webhook endpoints" {
        $endpoint = kubectl get endpoints aws-load-balancer-webhook-service -n kube-system -o jsonpath='{.subsets[0].addresses[0].ip}' 2>$null
        return -not [string]::IsNullOrWhiteSpace($endpoint)
    } 300 10
}

Run-Step "Terraform apply - platform-services" {
    terraform "-chdir=$ServicesDir" apply -auto-approve
}

if (-not $SkipKubeconfig) {
    Run-Step "Waiting for External Secrets rollout" {
        kubectl rollout status deployment/external-secrets -n external-secrets --timeout=5m
    }

    Run-Step "Waiting for ArgoCD server rollout" {
        kubectl rollout status deployment/argocd-server -n argocd --timeout=10m
    }

    Run-Step "Waiting for ArgoCD repo-server rollout" {
        kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=10m
    }

    Run-Step "Waiting for ArgoCD Application CRD" {
        kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=120s
    }

    Run-Step "Waiting for External Secrets CRDs" {
        kubectl wait --for=condition=Established crd/clustersecretstores.external-secrets.io --timeout=120s
        kubectl wait --for=condition=Established crd/externalsecrets.external-secrets.io --timeout=120s
    }

    Wait-Until "ArgoCD ingress load balancer hostname" {
        $hostname = kubectl get ingress argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null
        return -not [string]::IsNullOrWhiteSpace($hostname)
    } 600 20
}

Run-Step "Terraform apply - platform-bootstrap" {
    terraform "-chdir=$BootstrapPlatformDir" apply -auto-approve
}

Run-Step "Terraform apply - platform-dns" {
    terraform "-chdir=$DnsDir" apply -auto-approve
}

Write-Host ""
Write-Host "Deployment complete." -ForegroundColor Green
