[CmdletBinding()]
param(
    [string]$AwsProfile = "personal",
    [version]$MinimumTerraformVersion = "1.8.0",
    [switch]$SkipAwsIdentity,
    [switch]$RequireOptionalTools
)

$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest

$script:Failures = 0
$script:Warnings = 0

function Write-Section {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Write-Pass {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([Parameter(Mandatory)][string]$Message)
    $script:Failures++
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Write-Warn {
    param([Parameter(Mandatory)][string]$Message)
    $script:Warnings++
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Get-FirstVersion {
    param([Parameter(Mandatory)][string]$Text)

    $match = [regex]::Match($Text, '(?<!\d)v?(\d+\.\d+\.\d+)(?:[-+][0-9A-Za-z.-]+)?')
    if ($match.Success) {
        return [version]$match.Groups[1].Value
    }
    return $null
}

function Invoke-CapturedCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = & $Command @Arguments 2>&1 | Out-String
    return [pscustomobject]@{
        Output   = $output.Trim()
        ExitCode = $LASTEXITCODE
    }
}

function Test-RequiredCommand {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$VersionArguments
    )

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        Write-Fail "$Name is not installed or is not on PATH."
        return $null
    }

    $result = Invoke-CapturedCommand -Command $Command -Arguments $VersionArguments
    if ($result.ExitCode -ne 0) {
        Write-Fail "$Name was found, but its version command failed: $($result.Output)"
        return $null
    }

    $firstLine = ($result.Output -split "`r?`n")[0]
    Write-Pass "$($Name): $firstLine"
    return $result.Output
}

function Test-OptionalCommand {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$VersionArguments
    )

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        if ($RequireOptionalTools) {
            Write-Fail "$Name is required by -RequireOptionalTools but was not found."
        }
        else {
            Write-Warn "$Name is not installed. It is useful but not required by deploy.ps1."
        }
        return
    }

    $result = Invoke-CapturedCommand -Command $Command -Arguments $VersionArguments
    if ($result.ExitCode -eq 0) {
        $firstLine = ($result.Output -split "`r?`n")[0]
        Write-Pass "$($Name): $firstLine"
    }
    else {
        Write-Warn "$Name was found, but its version command failed: $($result.Output)"
    }
}

Write-Section "Required command checks"

$awsOutput       = Test-RequiredCommand -Name "AWS CLI"   -Command "aws"       -VersionArguments @("--version")
$terraformOutput = Test-RequiredCommand -Name "Terraform" -Command "terraform" -VersionArguments @("version")
$kubectlOutput   = Test-RequiredCommand -Name "kubectl"   -Command "kubectl"   -VersionArguments @("version", "--client")
$helmOutput      = Test-RequiredCommand -Name "Helm"      -Command "helm"      -VersionArguments @("version")

if ($terraformOutput) {
    $terraformVersion = Get-FirstVersion $terraformOutput
    if (-not $terraformVersion) {
        Write-Fail "Could not parse the Terraform version."
    }
    elseif ($terraformVersion -lt $MinimumTerraformVersion) {
        Write-Fail "Terraform $terraformVersion is installed, but this repository requires Terraform $MinimumTerraformVersion or newer."
    }
    else {
        Write-Pass "Terraform version satisfies the repository requirement (>= $MinimumTerraformVersion)."
    }
}

if ($helmOutput) {
    $helmVersion = Get-FirstVersion $helmOutput
    if (-not $helmVersion) {
        Write-Warn "Could not parse the Helm version."
    }
    elseif ($helmVersion.Major -ge 4) {
        Write-Warn "Helm $helmVersion is installed. This repository was originally developed with Helm 3; test Helm 4 carefully if Helm-related errors occur."
    }
    elseif ($helmVersion.Major -eq 3) {
        Write-Pass "Helm 3 compatibility check passed."
    }
    else {
        Write-Fail "Helm $helmVersion is too old. Helm 3 or newer is required."
    }
}

Write-Section "Optional supporting tools"
Test-OptionalCommand -Name "Git" -Command "git" -VersionArguments @("--version")
Test-OptionalCommand -Name "jq"  -Command "jq"  -VersionArguments @("--version")

if (-not $SkipAwsIdentity -and (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Section "AWS identity check"

    $previousProfile = $env:AWS_PROFILE
    try {
        if (-not [string]::IsNullOrWhiteSpace($AwsProfile)) {
            $env:AWS_PROFILE = $AwsProfile
        }

        $identityResult = Invoke-CapturedCommand -Command "aws" -Arguments @(
            "sts", "get-caller-identity",
            "--output", "json"
        )

        if ($identityResult.ExitCode -ne 0) {
            Write-Fail "AWS authentication failed for profile '$AwsProfile': $($identityResult.Output)"
        }
        else {
            try {
                $identity = $identityResult.Output | ConvertFrom-Json
                Write-Pass "AWS authentication succeeded for profile '$AwsProfile'."
                Write-Host "       Account: $($identity.Account)"
                Write-Host "       ARN:     $($identity.Arn)"
            }
            catch {
                Write-Fail "AWS returned an unexpected identity response: $($identityResult.Output)"
            }
        }
    }
    finally {
        if ($null -eq $previousProfile) {
            Remove-Item Env:AWS_PROFILE -ErrorAction SilentlyContinue
        }
        else {
            $env:AWS_PROFILE = $previousProfile
        }
    }
}
elseif ($SkipAwsIdentity) {
    Write-Warn "AWS identity validation was skipped."
}

Write-Section "Repository checks"

$repoRoot = Split-Path -Parent $PSScriptRoot
$deployScript = Join-Path $repoRoot "deploy.ps1"
$backendConfig = Join-Path $repoRoot "infra\terraform\environments\dev\backend.hcl"

if (Test-Path $deployScript) {
    Write-Pass "Found deploy.ps1 at $deployScript"
}
else {
    Write-Warn "deploy.ps1 was not found relative to this validation script. Place this file in the repository's scripts directory."
}

if (Test-Path $backendConfig) {
    Write-Pass "Found dev backend configuration."
}
else {
    Write-Warn "Dev backend configuration was not found at the expected path: $backendConfig"
}

Write-Section "Result"

if ($script:Failures -gt 0) {
    Write-Host "Prerequisite validation FAILED with $($script:Failures) failure(s) and $($script:Warnings) warning(s)." -ForegroundColor Red
    Write-Host "Run .\scripts\install-prerequisites.ps1 to install missing tools."
    exit 1
}

if ($script:Warnings -gt 0) {
    Write-Host "Prerequisite validation PASSED with $($script:Warnings) warning(s)." -ForegroundColor Yellow
}
else {
    Write-Host "Prerequisite validation PASSED." -ForegroundColor Green
}

exit 0