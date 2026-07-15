param(
    [switch]$IncludeOptionalTools,
    [switch]$ForceUpgrade,
    [string]$AwsProfile = "personal"
)

$ErrorActionPreference = "Stop"

function Write-Section {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Write-Ok {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable(
        "Path",
        "Machine"
    )

    $userPath = [Environment]::GetEnvironmentVariable(
        "Path",
        "User"
    )

    $env:Path = "$machinePath;$userPath"
}

function Add-WingetLinksToUserPath {
    $wingetLinks = Join-Path `
        $env:LOCALAPPDATA `
        "Microsoft\WinGet\Links"

    if (-not (Test-Path $wingetLinks)) {
        return
    }

    $userPath = [Environment]::GetEnvironmentVariable(
        "Path",
        "User"
    )

    $existingEntries = @(
        $userPath -split ";" |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
    )

    $alreadyPresent = $existingEntries |
        Where-Object {
            $_.TrimEnd("\") -ieq $wingetLinks.TrimEnd("\")
        }

    if (-not $alreadyPresent) {
        $newUserPath = if (
            [string]::IsNullOrWhiteSpace($userPath)
        ) {
            $wingetLinks
        }
        else {
            "$userPath;$wingetLinks"
        }

        [Environment]::SetEnvironmentVariable(
            "Path",
            $newUserPath,
            "User"
        )

        Write-Ok "Added Winget command links directory to the user PATH."
    }
}

function Find-WingetExecutable {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutableName
    )

    $searchRoot = Join-Path `
        $env:LOCALAPPDATA `
        "Microsoft\WinGet\Packages"

    if (-not (Test-Path $searchRoot)) {
        return $null
    }

    $result = Get-ChildItem `
        -Path $searchRoot `
        -Recurse `
        -Filter $ExecutableName `
        -File `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($result) {
        return $result.FullName
    }

    return $null
}

function Add-ExecutableDirectoryToUserPath {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath
    )

    $directory = Split-Path `
        -Path $ExecutablePath `
        -Parent

    if ([string]::IsNullOrWhiteSpace($directory)) {
        return
    }

    $userPath = [Environment]::GetEnvironmentVariable(
        "Path",
        "User"
    )

    $existingEntries = @(
        $userPath -split ";" |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
    )

    $alreadyPresent = $existingEntries |
        Where-Object {
            $_.TrimEnd("\") -ieq $directory.TrimEnd("\")
        }

    if (-not $alreadyPresent) {
        $newUserPath = if (
            [string]::IsNullOrWhiteSpace($userPath)
        ) {
            $directory
        }
        else {
            "$userPath;$directory"
        }

        [Environment]::SetEnvironmentVariable(
            "Path",
            $newUserPath,
            "User"
        )

        Write-Ok "Added $directory to the user PATH."
    }
}

function Get-CommandPath {
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )

    $resolved = Get-Command `
        $Command `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($resolved) {
        return $resolved.Source
    }

    return $null
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string]$PackageId
    )

    Refresh-Path

    $existingCommand = Get-CommandPath -Command $Command

    if ($existingCommand -and -not $ForceUpgrade) {
        Write-Ok "$Name is already installed."
        return
    }

    if ($ForceUpgrade) {
        Write-Host "Installing or upgrading $Name ($PackageId)..."

        & winget upgrade `
            --id $PackageId `
            --exact `
            --accept-package-agreements `
            --accept-source-agreements `
            --disable-interactivity

        $wingetExitCode = $LASTEXITCODE
    }
    else {
        Write-Host "Installing $Name ($PackageId)..."

        & winget install `
            --id $PackageId `
            --exact `
            --accept-package-agreements `
            --accept-source-agreements `
            --disable-interactivity

        $wingetExitCode = $LASTEXITCODE
    }

    Add-WingetLinksToUserPath
    Refresh-Path

    $resolvedCommand = Get-CommandPath -Command $Command

    if ($resolvedCommand) {
        Write-Ok "$Name is available at $resolvedCommand"
        return
    }

    $executableName = if ($Command.EndsWith(".exe")) {
        $Command
    }
    else {
        "$Command.exe"
    }

    $locatedExecutable = Find-WingetExecutable `
        -ExecutableName $executableName

    if ($locatedExecutable) {
        Write-Warn "$Name was installed, but it was not initially available on PATH."

        Add-ExecutableDirectoryToUserPath `
            -ExecutablePath $locatedExecutable

        Refresh-Path

        $resolvedCommand = Get-CommandPath -Command $Command

        if ($resolvedCommand) {
            Write-Ok "$Name is now available at $resolvedCommand"
            return
        }
    }

    throw @"
Winget returned exit code $wingetExitCode for $Name, but '$Command'
is still not available on PATH.

Winget may have reported that the package was already installed or that
no upgrade was available. Close and reopen PowerShell, then run:

    $Command --version

You can locate the executable manually with:

    Get-ChildItem "`$env:LOCALAPPDATA\Microsoft\WinGet\Packages" `
        -Recurse `
        -Filter "$executableName" `
        -ErrorAction SilentlyContinue

Package ID:

    $PackageId
"@
}

function Show-InstalledVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $commandInfo = Get-Command `
        $Command `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $commandInfo) {
        Write-Warn "$Name is not available on PATH."
        return
    }

    try {
        $output = & $Command @Arguments 2>&1

        $firstLine = $output |
            Select-Object -First 1

        Write-Ok "$($Name): $firstLine"
    }
    catch {
        Write-Warn "Unable to read the installed version of $Name."
    }
}

Write-Section "Checking Windows Package Manager"

$wingetCommand = Get-Command `
    winget `
    -ErrorAction SilentlyContinue

if (-not $wingetCommand) {
    throw @"
Windows Package Manager (winget) is required but was not found.

Install or update App Installer from the Microsoft Store, then open a
new PowerShell window and rerun this script.
"@
}

$wingetVersion = & winget --version
Write-Ok "winget is available: $wingetVersion"

Add-WingetLinksToUserPath
Refresh-Path

Write-Section "Installing required tools"

$requiredTools = @(
    @{
        Name      = "AWS CLI"
        Command   = "aws"
        PackageId = "Amazon.AWSCLI"
    },
    @{
        Name      = "Terraform"
        Command   = "terraform"
        PackageId = "Hashicorp.Terraform"
    },
    @{
        Name      = "kubectl"
        Command   = "kubectl"
        PackageId = "Kubernetes.kubectl"
    },
    @{
        Name      = "Helm"
        Command   = "helm"
        PackageId = "Helm.Helm"
    }
)

foreach ($tool in $requiredTools) {
    Install-WingetPackage `
        -Name $tool.Name `
        -Command $tool.Command `
        -PackageId $tool.PackageId
}

if ($IncludeOptionalTools) {
    Write-Section "Installing optional supporting tools"

    $optionalTools = @(
        @{
            Name      = "Git"
            Command   = "git"
            PackageId = "Git.Git"
        },
        @{
            Name      = "jq"
            Command   = "jq"
            PackageId = "jqlang.jq"
        }
    )

    foreach ($tool in $optionalTools) {
        Install-WingetPackage `
            -Name $tool.Name `
            -Command $tool.Command `
            -PackageId $tool.PackageId
    }
}

Refresh-Path

Write-Section "Installed versions"

Show-InstalledVersion `
    -Name "AWS CLI" `
    -Command "aws" `
    -Arguments @("--version")

Show-InstalledVersion `
    -Name "Terraform" `
    -Command "terraform" `
    -Arguments @("version")

Show-InstalledVersion `
    -Name "kubectl" `
    -Command "kubectl" `
    -Arguments @("version", "--client")

Show-InstalledVersion `
    -Name "Helm" `
    -Command "helm" `
    -Arguments @("version")

if ($IncludeOptionalTools) {
    Show-InstalledVersion `
        -Name "Git" `
        -Command "git" `
        -Arguments @("--version")

    Show-InstalledVersion `
        -Name "jq" `
        -Command "jq" `
        -Arguments @("--version")
}

Write-Section "Running prerequisite validation"

$validationScript = Join-Path `
    $PSScriptRoot `
    "validate-prerequisites.ps1"

if (Test-Path $validationScript) {
    & $validationScript -AwsProfile $AwsProfile

    if ($LASTEXITCODE -ne 0) {
        throw "Prerequisite validation failed."
    }
}
else {
    Write-Warn "Validation script was not found at $validationScript"
}

Write-Section "Installation complete"

Write-Ok "Prerequisite installation completed successfully."
Write-Host ""
Write-Host "You can now run:" -ForegroundColor Cyan
Write-Host ""
Write-Host "    .\deploy.ps1" -ForegroundColor White
Write-Host ""
