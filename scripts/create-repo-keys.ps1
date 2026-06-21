param(
    [string]$SecretName = "dev/argocd/repo/hello-aws-eks",
    [string]$Region = "us-east-1",
    [string]$Profile = "terraform"
)

$ErrorActionPreference = "Stop"

Write-Host "Creating/updating AWS Secrets Manager secret: $SecretName"

$username = Read-Host "Enter Git repo username"
$secureToken = Read-Host "Enter Git repo token" -AsSecureString

$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
try {
    $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
}

$secretObject = @{
    username = $username
    password = $token
}

$secretString = $secretObject | ConvertTo-Json -Compress

$exists = $true

try {
    aws secretsmanager describe-secret `
        --secret-id $SecretName `
        --region $Region `
        --profile $Profile `
        *> $null
}
catch {
    $exists = $false
}

if ($exists) {
    Write-Host "Secret exists. Updating value..."

    aws secretsmanager put-secret-value `
        --secret-id $SecretName `
        --secret-string $secretString `
        --region $Region `
        --profile $Profile `
        | Out-Null

    Write-Host "Secret updated successfully."
}
else {
    Write-Host "Secret does not exist. Creating..."

    aws secretsmanager create-secret `
        --name $SecretName `
        --secret-string $secretString `
        --region $Region `
        --profile $Profile `
        | Out-Null

    Write-Host "Secret created successfully."
}