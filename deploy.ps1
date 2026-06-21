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

function Run-Step($Message, $ScriptBlock) {
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
    & $ScriptBlock
    if ($LASTEXITCODE -ne 0) {
        throw "Step failed: $Message"
    }
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

$BootstrapDir = "infra/terraform/bootstrap"
$EnvDir = "infra/terraform/environments/$Environment"

Require-Command terraform
Require-Command aws

if (-not $SkipKubeconfig) {
    Require-Command kubectl
}

if (-not (Test-Path $BootstrapDir)) {
    throw "Bootstrap directory not found: $BootstrapDir"
}

if (-not (Test-Path $EnvDir)) {
    throw "Environment directory not found: $EnvDir"
}

Run-Step "Checking AWS identity" {
    aws sts get-caller-identity
}

if (-not $SkipBootstrap) {
    Run-Step "Terraform init - bootstrap" {
        & terraform "-chdir=$BootstrapDir" init
    }

    if ($PlanOnly) {
        Run-Step "Terraform plan - bootstrap" {
            & terraform "-chdir=$BootstrapDir" plan
        }
    }
    else {
        Run-Step "Terraform apply - bootstrap" {
            & terraform "-chdir=$BootstrapDir" apply -auto-approve
        }

        if ($LASTEXITCODE -ne 0) {
            Write-Host "Bootstrap apply failed. Attempting to import existing bootstrap resources..." -ForegroundColor Yellow

            & terraform "-chdir=$BootstrapDir" import aws_s3_bucket.terraform_state "practice-eks-dev-terraform-state-dds-20260619"
            & terraform "-chdir=$BootstrapDir" import aws_dynamodb_table.terraform_locks "practice-eks-dev-terraform-locks"

            Write-Host "Retrying bootstrap apply..." -ForegroundColor Yellow
            & terraform "-chdir=$BootstrapDir" apply -auto-approve
        }
    }
}

Run-Step "Terraform init - $Environment" {
    terraform "-chdir=$EnvDir" init
}

if ($PlanOnly) {
    Run-Step "Terraform plan - $Environment" {
        terraform "-chdir=$EnvDir" plan
    }

    Write-Host ""
    Write-Host "Plan complete. No changes were applied." -ForegroundColor Yellow
    exit 0
}

Run-Step "Terraform apply - $Environment" {
    terraform "-chdir=$EnvDir" apply -auto-approve
}

if (-not $SkipKubeconfig) {
    Run-Step "Updating kubeconfig" {
        $clusterName = & terraform "-chdir=$EnvDir" output -raw cluster_name
        $region = "us-east-1"

        & aws eks update-kubeconfig `
            --region $region `
            --name $clusterName
    }

    Run-Step "Verifying EKS nodes" {
        kubectl get nodes
    }
}

Write-Host ""
Write-Host "Deployment complete." -ForegroundColor Green