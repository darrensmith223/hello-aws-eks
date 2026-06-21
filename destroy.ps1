param(
    [string]$Environment = "dev",
    [switch]$DestroyBootstrap
)

$ErrorActionPreference = "Stop"

function Require-Command($Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Run-Step($Message, $ScriptBlock) {
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Red
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

if (-not (Test-Path $EnvDir)) {
    throw "Environment directory not found: $EnvDir"
}

Run-Step "Checking AWS identity" {
    aws sts get-caller-identity
}

Write-Host ""
Write-Host "This will destroy the EKS environment: $Environment" -ForegroundColor Yellow
$confirm = Read-Host "Type DESTROY to continue"

if ($confirm -ne "DESTROY") {
    Write-Host "Destroy cancelled."
    exit 0
}

Run-Step "Terraform init - $Environment" {
    terraform "-chdir=$EnvDir" init
}

Run-Step "Terraform destroy - $Environment" {
    terraform "-chdir=$EnvDir" destroy -auto-approve
}

if ($DestroyBootstrap) {
    if (-not (Test-Path $BootstrapDir)) {
        throw "Bootstrap directory not found: $BootstrapDir"
    }

    Write-Host ""
    Write-Host "You also requested bootstrap destruction." -ForegroundColor Yellow
    $confirmBootstrap = Read-Host "Type DESTROY-BOOTSTRAP to continue"

    if ($confirmBootstrap -eq "DESTROY-BOOTSTRAP") {
        Run-Step "Terraform init - bootstrap" {
            terraform "-chdir=$BootstrapDir" init
        }

        Run-Step "Terraform destroy - bootstrap" {
            terraform "-chdir=$BootstrapDir" destroy -auto-approve
        }
    }
    else {
        Write-Host "Bootstrap destroy skipped."
    }
}

Write-Host ""
Write-Host "Destroy complete." -ForegroundColor Green