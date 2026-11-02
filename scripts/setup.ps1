# =============================================================================
# setup.ps1 -- Automated Placeholder Replacement Script (PowerShell)
# Replaces placeholders across online-boutique-app and online-boutique-config
# =============================================================================

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# Determine repository root directories
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDir = (Resolve-Path "$ScriptDir\..").Path
$ConfigDirCandidate = "$AppDir\..\online-boutique-config"

# --- Error Checking: Directory Validation ---
if (-not (Test-Path $ConfigDirCandidate)) {
    Write-Host "[!] Error: Directory 'online-boutique-config' not found at:" -ForegroundColor Red
    Write-Host "    $ConfigDirCandidate" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please ensure both repositories are cloned side by side in the same parent directory:" -ForegroundColor Yellow
    Write-Host "  <workspace>/"
    Write-Host "  |-- online-boutique-app/"
    Write-Host "  \-- online-boutique-config/"
    exit 1
}

$ConfigDir = (Resolve-Path $ConfigDirCandidate).Path
$WorkspaceParent = (Resolve-Path "$AppDir\..").Path

Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host "   Online Boutique - Automated Setup & Configuration Script" -ForegroundColor Cyan
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host "App Directory:    $AppDir"
Write-Host "Config Directory: $ConfigDir"
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host ""

# --- Interactive Prompts ---

# 1. AWS Account ID (12 digits)
while ($true) {
    $AwsAccountId = Read-Host "Enter AWS Account ID (12 digits)"
    if ($AwsAccountId -match '^\d{12}$') {
        break
    } else {
        Write-Host "  [!] Error: AWS Account ID must be exactly 12 numeric digits (e.g., 123456789012)." -ForegroundColor Red
    }
}

# 2. AWS Region
$AwsRegion = Read-Host "Enter AWS Region [ap-southeast-1]"
if ([string]::IsNullOrWhiteSpace($AwsRegion)) { $AwsRegion = "ap-southeast-1" }

# 3. IAM Username
while ($true) {
    $IamUsername = Read-Host "Enter IAM Username (for cluster admin access)"
    if (-not [string]::IsNullOrWhiteSpace($IamUsername)) {
        break
    } else {
        Write-Host "  [!] Error: IAM Username cannot be empty." -ForegroundColor Red
    }
}

# 4. GitHub Organization or Username
while ($true) {
    $GithubOrg = Read-Host "Enter GitHub Organization or Username"
    if (-not [string]::IsNullOrWhiteSpace($GithubOrg)) {
        break
    } else {
        Write-Host "  [!] Error: GitHub Organization/Username cannot be empty." -ForegroundColor Red
    }
}

# 5. GitHub Username for README attribution
$GithubUsername = Read-Host "Enter GitHub Username for README attribution [$GithubOrg]"
if ([string]::IsNullOrWhiteSpace($GithubUsername)) { $GithubUsername = $GithubOrg }

# 6. Contact Email
$UserEmail = Read-Host "Enter contact email for README (optional, press Enter to skip)"

# 7. EKS Cluster Names
$EksClusterDev = Read-Host "Enter Dev EKS Cluster Name [online-boutique-dev]"
if ([string]::IsNullOrWhiteSpace($EksClusterDev)) { $EksClusterDev = "online-boutique-dev" }

$EksClusterStaging = Read-Host "Enter Staging EKS Cluster Name [online-boutique-staging]"
if ([string]::IsNullOrWhiteSpace($EksClusterStaging)) { $EksClusterStaging = "online-boutique-staging" }

# 8. Redis Endpoint
$RedisEndpoint = Read-Host "Enter Redis Endpoint (optional, press Enter to skip for later)"

# 9. Grafana Admin Password
$GrafanaAdminPassword = Read-Host "Enter Grafana Admin Password [admin]"
if ([string]::IsNullOrWhiteSpace($GrafanaAdminPassword)) { $GrafanaAdminPassword = "admin" }

# 10. SonarCloud Org & Project Key
$SonarOrg = Read-Host "Enter SonarCloud Organization (optional, press Enter to skip)"
$SonarProjectKey = Read-Host "Enter SonarCloud Project Key (optional, press Enter to skip)"

Write-Host ""
Write-Host "Replacing placeholders across both repositories..." -ForegroundColor Yellow
Write-Host "---------------------------------------------------------------------"

# --- Discover Target Files ---
$targetExtensions = @("*.tf", "*.tfvars", "*.example", "*.yaml", "*.yml", "*.properties", "*.md", "CODEOWNERS")

$filesToScan = Get-ChildItem -Path $AppDir, $ConfigDir -Recurse -File | Where-Object {
    $fullName = $_.FullName
    $matchExt = $false
    foreach ($ext in $targetExtensions) {
        if ($_.Name -like $ext) {
            $matchExt = $true
            break
        }
    }
    $matchExt -and `
    $fullName -notmatch '[\\/]\.git([\\/]|$)' -and `
    $fullName -notmatch '[\\/]\.terraform([\\/]|$)' -and `
    $fullName -notmatch '[\\/]node_modules([\\/]|$)' -and `
    $fullName -notmatch '[\\/]scripts[\\/]setup\.' -and `
    $_.Name -ne 'SETUP.md'
}

$modifiedFiles = @()
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# --- Process Replacements ---
foreach ($file in $filesToScan) {
    $contentLines = Get-Content -Path $file.FullName
    $hasPlaceholder = $false
    foreach ($line in $contentLines) {
        if ($line -match '<(AWS_ACCOUNT_ID|YOUR_AWS_ACCOUNT_ID|AWS_REGION|YOUR_IAM_USERNAME|GITHUB_ORG|YOUR_GITHUB_ORG|YOUR_GITHUB_USERNAME|YOUR_EMAIL|GRAFANA_ADMIN_PASSWORD|EKS_CLUSTER_NAME|REDIS_ENDPOINT|YOUR_SONAR_ORG|YOUR_SONAR_PROJECT_KEY)>') {
            $hasPlaceholder = $true
            break
        }
    }

    if ($hasPlaceholder) {
        $isStaging = $file.FullName -match '[\\/]staging[\\/]'
        $targetEksCluster = if ($isStaging) { $EksClusterStaging } else { $EksClusterDev }

        $changed = $false
        $newLines = $contentLines | ForEach-Object {
            $currentLine = $_
            $origLine = $currentLine

            $currentLine = $currentLine -replace '<AWS_ACCOUNT_ID>', $AwsAccountId
            $currentLine = $currentLine -replace '<YOUR_AWS_ACCOUNT_ID>', $AwsAccountId
            $currentLine = $currentLine -replace '<AWS_REGION>', $AwsRegion
            $currentLine = $currentLine -replace '<YOUR_IAM_USERNAME>', $IamUsername
            $currentLine = $currentLine -replace '<GITHUB_ORG>', $GithubOrg
            $currentLine = $currentLine -replace '<YOUR_GITHUB_ORG>', $GithubOrg
            $currentLine = $currentLine -replace '<YOUR_GITHUB_USERNAME>', $GithubUsername
            $currentLine = $currentLine -replace '<GRAFANA_ADMIN_PASSWORD>', $GrafanaAdminPassword
            $currentLine = $currentLine -replace '<EKS_CLUSTER_NAME>', $targetEksCluster

            if (-not [string]::IsNullOrWhiteSpace($UserEmail)) {
                $currentLine = $currentLine -replace '<YOUR_EMAIL>', $UserEmail
            }

            if (-not [string]::IsNullOrWhiteSpace($RedisEndpoint)) {
                $currentLine = $currentLine -replace '<REDIS_ENDPOINT>', $RedisEndpoint
            }

            if (-not [string]::IsNullOrWhiteSpace($SonarOrg)) {
                $currentLine = $currentLine -replace '<YOUR_SONAR_ORG>', $SonarOrg
            }

            if (-not [string]::IsNullOrWhiteSpace($SonarProjectKey)) {
                $currentLine = $currentLine -replace '<YOUR_SONAR_PROJECT_KEY>', $SonarProjectKey
            }

            if ($currentLine -ne $origLine) {
                $changed = $true
            }
            $currentLine
        }

        if ($changed) {
            [System.IO.File]::WriteAllLines($file.FullName, [string[]]$newLines, $utf8NoBom)
            $modifiedFiles += $file.FullName
        }
    }
}

# --- Output Summary ---
Write-Host ""
Write-Host "=====================================================================" -ForegroundColor Green
Write-Host "   Modified Files ($($modifiedFiles.Count) files updated)" -ForegroundColor Green
Write-Host "=====================================================================" -ForegroundColor Green
if ($modifiedFiles.Count -eq 0) {
    Write-Host "No files modified. All placeholders may have already been replaced."
} else {
    foreach ($modFile in $modifiedFiles) {
        $relPath = $modFile.Replace("$WorkspaceParent\", "").Replace("$WorkspaceParent/", "")
        Write-Host "  [MODIFIED] $relPath" -ForegroundColor Cyan
    }
}

Write-Host ""
Write-Host "=====================================================================" -ForegroundColor Green
Write-Host "   Configuration Summary" -ForegroundColor Green
Write-Host "=====================================================================" -ForegroundColor Green
Write-Host "  AWS Account ID:         $AwsAccountId"
Write-Host "  AWS Region:             $AwsRegion"
Write-Host "  IAM Username:           $IamUsername"
Write-Host "  GitHub Org / Owner:     $GithubOrg"
Write-Host "  GitHub Username:        $GithubUsername"
$emailDisplay = if ([string]::IsNullOrWhiteSpace($UserEmail)) { "[Skipped]" } else { $UserEmail }
Write-Host "  Contact Email:          $emailDisplay"
Write-Host "  Dev EKS Cluster:        $EksClusterDev"
Write-Host "  Staging EKS Cluster:    $EksClusterStaging"
$redisDisplay = if ([string]::IsNullOrWhiteSpace($RedisEndpoint)) { "[Skipped - to be configured after ElastiCache provision]" } else { $RedisEndpoint }
Write-Host "  Redis Endpoint:         $redisDisplay"
Write-Host "  Grafana Admin Password: $GrafanaAdminPassword"
$sonarOrgDisplay = if ([string]::IsNullOrWhiteSpace($SonarOrg)) { "[Skipped]" } else { $SonarOrg }
Write-Host "  SonarCloud Org:         $sonarOrgDisplay"
$sonarKeyDisplay = if ([string]::IsNullOrWhiteSpace($SonarProjectKey)) { "[Skipped]" } else { $SonarProjectKey }
Write-Host "  SonarCloud Project Key: $sonarKeyDisplay"
Write-Host "=====================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "1. Verify changes with 'git diff' in both repositories."
Write-Host "2. Commit and push changes if desired."
Write-Host "3. Follow SETUP.md Step 5 to bootstrap the S3 backend:"
Write-Host "     cd terraform-aws/global/s3-backend"
Write-Host "     cp backend.tf.example backend.tf"
Write-Host "     terraform init && terraform apply"
Write-Host "=====================================================================" -ForegroundColor Green
