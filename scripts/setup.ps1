# =============================================================================
# setup.ps1 -- Automated Setup & Local Configuration Script (PowerShell)
# Generates local gitignored configuration files and configures config repo branch.
# Does NOT commit or push any changes.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AwsAccountId = $env:AWS_ACCOUNT_ID,

    [Parameter(Mandatory = $false)]
    [string]$AwsRegion = $(if ($env:AWS_REGION) { $env:AWS_REGION } else { "ap-southeast-1" }),

    [Parameter(Mandatory = $false)]
    [string]$GithubOrg = $env:GITHUB_ORG,

    [Parameter(Mandatory = $false)]
    [string]$IamUsername = $env:IAM_USERNAME,

    [Parameter(Mandatory = $false)]
    [string]$ConfigRepoPath = $(if ($env:CONFIG_REPO_PATH) { $env:CONFIG_REPO_PATH } else { "../online-boutique-config" }),

    [Parameter(Mandatory = $false)]
    [string]$RedisEndpoint = $env:REDIS_ENDPOINT,

    [Parameter(Mandatory = $false)]
    [string]$TargetEnv = $(if ($env:ENV) { $env:ENV } else { "dev" })
)

$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
    param (
        [string]$Path,
        [string]$Content
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# Determine repository root directory
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDir = (Resolve-Path "$ScriptDir\..").Path

Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host "   Online Boutique -- Automated Setup & Configuration Script" -ForegroundColor Cyan
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host "App Directory: $AppDir"
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host ""

$isAllSet = (-not [string]::IsNullOrWhiteSpace($AwsAccountId)) -and `
            (-not [string]::IsNullOrWhiteSpace($AwsRegion)) -and `
            (-not [string]::IsNullOrWhiteSpace($GithubOrg)) -and `
            (-not [string]::IsNullOrWhiteSpace($IamUsername))

$isInteractive = [System.Environment]::UserInteractive -and (-not [Console]::IsInputRedirected) -and (-not $isAllSet)

if ($isInteractive) {
    if ([string]::IsNullOrWhiteSpace($AwsAccountId)) {
        while ($true) {
            $AwsAccountId = Read-Host "Enter AWS Account ID (12 digits)"
            if ($AwsAccountId -match '^\d{12}$') {
                break
            } else {
                Write-Host "  [!] Error: AWS Account ID must be exactly 12 numeric digits (e.g., 123456789012)." -ForegroundColor Red
            }
        }
    } elseif ($AwsAccountId -notmatch '^\d{12}$') {
        Write-Error "Invalid AWS Account ID '$AwsAccountId'. Must be exactly 12 numeric digits."
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace($AwsRegion)) {
        $regInput = Read-Host "Enter AWS Region [ap-southeast-1]"
        if (-not [string]::IsNullOrWhiteSpace($regInput)) {
            $AwsRegion = $regInput
        } else {
            $AwsRegion = "ap-southeast-1"
        }
    }

    if ([string]::IsNullOrWhiteSpace($GithubOrg)) {
        while ($true) {
            $GithubOrg = Read-Host "Enter GitHub Organization or Username"
            if (-not [string]::IsNullOrWhiteSpace($GithubOrg)) {
                break
            } else {
                Write-Host "  [!] Error: GitHub Organization/Username cannot be empty." -ForegroundColor Red
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($IamUsername)) {
        while ($true) {
            $IamUsername = Read-Host "Enter IAM Username (for cluster admin access)"
            if (-not [string]::IsNullOrWhiteSpace($IamUsername)) {
                break
            } else {
                Write-Host "  [!] Error: IAM Username cannot be empty." -ForegroundColor Red
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($ConfigRepoPath)) {
        $cfgInput = Read-Host "Enter path to online-boutique-config [../online-boutique-config]"
        if (-not [string]::IsNullOrWhiteSpace($cfgInput)) {
            $ConfigRepoPath = $cfgInput
        } else {
            $ConfigRepoPath = "../online-boutique-config"
        }
    }

    if ($null -eq $RedisEndpoint -or [string]::IsNullOrWhiteSpace($RedisEndpoint)) {
        $RedisEndpoint = Read-Host "Enter Redis Endpoint (optional, press Enter to skip)"
    }

    if ([string]::IsNullOrWhiteSpace($TargetEnv)) {
        $envInput = Read-Host "Enter Target Environment (dev/staging) [dev]"
        if (-not [string]::IsNullOrWhiteSpace($envInput)) {
            $TargetEnv = $envInput
        } else {
            $TargetEnv = "dev"
        }
    }
} else {
    if ([string]::IsNullOrWhiteSpace($AwsAccountId)) {
        Write-Error "AWS Account ID is required (set -AwsAccountId or env:AWS_ACCOUNT_ID)."
        exit 1
    }
    if ($AwsAccountId -notmatch '^\d{12}$') {
        Write-Error "Invalid AWS Account ID '$AwsAccountId'. Must be exactly 12 numeric digits."
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($AwsRegion)) {
        $AwsRegion = "ap-southeast-1"
    }
    if ([string]::IsNullOrWhiteSpace($GithubOrg)) {
        Write-Error "GitHub Organization/Username is required (set -GithubOrg or env:GITHUB_ORG)."
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($IamUsername)) {
        Write-Error "IAM Username is required (set -IamUsername or env:IAM_USERNAME)."
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($ConfigRepoPath)) {
        $ConfigRepoPath = "../online-boutique-config"
    }
    if ([string]::IsNullOrWhiteSpace($TargetEnv)) {
        $TargetEnv = "dev"
    }
}

# Resolve Config Directory
if ([System.IO.Path]::IsPathRooted($ConfigRepoPath)) {
    $ConfigDirCandidate = $ConfigRepoPath
} else {
    $ConfigDirCandidate = Join-Path $AppDir $ConfigRepoPath
}

if (-not (Test-Path $ConfigDirCandidate)) {
    Write-Error "Directory '$ConfigRepoPath' not found at '$ConfigDirCandidate'."
    exit 1
}

$ConfigDir = (Resolve-Path $ConfigDirCandidate).Path
$configGitDir = Join-Path $ConfigDir ".git"
if (-not (Test-Path $configGitDir)) {
    Write-Error "'$ConfigDir' is not a git repository."
    exit 1
}

Write-Host ""
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host "   Configuration Parameters" -ForegroundColor Cyan
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host "  AWS Account ID:     $AwsAccountId"
Write-Host "  AWS Region:         $AwsRegion"
Write-Host "  GitHub Org:         $GithubOrg"
Write-Host "  IAM Username:       $IamUsername"
Write-Host "  Target Environment: $TargetEnv"
Write-Host "  Config Repo Path:   $ConfigDir"
Write-Host "  Redis Endpoint:     $(if ($RedisEndpoint) { $RedisEndpoint } else { '[Not provided - placeholder will be kept]' })"
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host ""

# -----------------------------------------------------------------------------
# Action 1: Generate gitignored local files ONLY
# -----------------------------------------------------------------------------
Write-Host "Generating gitignored local Terraform files..." -ForegroundColor Green

$backendDirs = @(
    (Join-Path $AppDir "terraform-aws\environments\dev"),
    (Join-Path $AppDir "terraform-aws\environments\staging"),
    (Join-Path $AppDir "terraform-aws\global\ecr"),
    (Join-Path $AppDir "terraform-aws\global\github-oidc")
)

foreach ($dir in $backendDirs) {
    if (-not (Test-Path $dir)) {
        Write-Error "Directory '$dir' does not exist."
        exit 1
    }
    $backendFile = Join-Path $dir "backend.hcl"
    $backendLines = @(
        "bucket = `"online-boutique-tfstate-$AwsAccountId`"",
        "region = `"$AwsRegion`""
    )
    $backendContent = ($backendLines -join "`n") + "`n"
    Write-Utf8NoBom -Path $backendFile -Content $backendContent

    # Verify gitignored
    $relPath = $backendFile.Substring($AppDir.Length + 1).Replace("\", "/")
    $null = git -C $AppDir check-ignore -q $relPath
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Generated file '$relPath' is NOT ignored by git! Aborting to prevent credential leakage."
        Remove-Item -Path $backendFile -Force -ErrorAction SilentlyContinue
        exit 1
    }
    Write-Host "  [CREATED] $relPath (gitignored)"
}

# Generate terraform.tfvars in environments/<env>
$envDir = Join-Path $AppDir "terraform-aws\environments\$TargetEnv"
if (-not (Test-Path $envDir)) {
    Write-Error "Environment directory '$envDir' does not exist."
    exit 1
}

$tfvarsExample = Join-Path $envDir "terraform.tfvars.example"
$tfvarsFile = Join-Path $envDir "terraform.tfvars"
if (-not (Test-Path $tfvarsExample)) {
    Write-Error "Example file '$tfvarsExample' not found."
    exit 1
}

$rawTfvars = [System.IO.File]::ReadAllText($tfvarsExample)
$updatedTfvars = $rawTfvars -replace '<AWS_ACCOUNT_ID>', $AwsAccountId `
                            -replace '<IAM_USERNAME>', $IamUsername `
                            -replace 'aws_region\s*=\s*"[^"]*"', "aws_region   = `"$AwsRegion`""

Write-Utf8NoBom -Path $tfvarsFile -Content $updatedTfvars

$relTfvars = $tfvarsFile.Substring($AppDir.Length + 1).Replace("\", "/")
$null = git -C $AppDir check-ignore -q $relTfvars
if ($LASTEXITCODE -ne 0) {
    Write-Error "Generated file '$relTfvars' is NOT ignored by git! Aborting to prevent credential leakage."
    Remove-Item -Path $tfvarsFile -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Host "  [CREATED] $relTfvars (gitignored)"

# -----------------------------------------------------------------------------
# Action 2: Config repo configuration
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "Configuring config repository at: $ConfigDir..." -ForegroundColor Green

$targetBranch = "deploy/$TargetEnv"
$currentBranch = (git -C $ConfigDir rev-parse --abbrev-ref HEAD).Trim()

if ($currentBranch -ne $targetBranch) {
    $branchExists = $false
    $null = git -C $ConfigDir show-ref --verify --quiet "refs/heads/$targetBranch"
    if ($LASTEXITCODE -eq 0) {
        $branchExists = $true
    }

    if ($branchExists) {
        git -C $ConfigDir checkout $targetBranch
    } else {
        git -C $ConfigDir checkout -b $targetBranch
    }
    $currentBranch = (git -C $ConfigDir rev-parse --abbrev-ref HEAD).Trim()
}

if ($currentBranch -eq "main") {
    Write-Error "Config repository is on branch 'main'. Refusing to write real environment values to main branch."
    exit 1
}

if ($currentBranch -ne $targetBranch) {
    Write-Error "Failed to switch to branch '$targetBranch' (currently on '$currentBranch')."
    exit 1
}

$overlayDir = Join-Path $ConfigDir "overlays\$TargetEnv"
if (-not (Test-Path $overlayDir)) {
    Write-Error "Overlay directory '$overlayDir' does not exist."
    exit 1
}

$envPropsFile = Join-Path $overlayDir "env.properties"
$ecrRegistry = "${AwsAccountId}.dkr.ecr.${AwsRegion}.amazonaws.com"

if (-not [string]::IsNullOrWhiteSpace($RedisEndpoint)) {
    if ($RedisEndpoint.Contains(":")) {
        $redisAddr = $RedisEndpoint
    } else {
        $redisAddr = "${RedisEndpoint}:6379"
    }
} else {
    $redisAddr = "<REDIS_ENDPOINT>:6379"
}

$envPropsLines = @(
    "# Environment configuration for $TargetEnv overlay",
    "# IMPORTANT: In the public repository, keep placeholder values.",
    "# Real environment-specific values must ONLY be populated on the $targetBranch branch.",
    "",
    "ECR_REGISTRY=$ecrRegistry",
    "REDIS_ADDR=$redisAddr"
)
$envPropsContent = ($envPropsLines -join "`n") + "`n"

Write-Utf8NoBom -Path $envPropsFile -Content $envPropsContent

$relEnvProps = $envPropsFile.Substring($ConfigDir.Length + 1).Replace("\", "/")
Write-Host "  [UPDATED] $relEnvProps (on branch $targetBranch)"

if ([string]::IsNullOrWhiteSpace($RedisEndpoint)) {
    Write-Host ""
    Write-Host "  [WARNING] REDIS_ENDPOINT was not set. Left placeholder '<REDIS_ENDPOINT>:6379' in overlays/$TargetEnv/env.properties." -ForegroundColor Yellow
    Write-Host "            After provisioning infrastructure with 'terraform apply', update REDIS_ADDR using" -ForegroundColor Yellow
    Write-Host "            the output 'redis_connection_string' from terraform-aws/environments/$TargetEnv." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  [IMPORTANT] Config changes were written on branch '$targetBranch'." -ForegroundColor Yellow
Write-Host "              Commit and push ONLY to '$targetBranch'. NEVER commit real values to 'main'!" -ForegroundColor Yellow
Write-Host "              (No automatic commits were made)."

# -----------------------------------------------------------------------------
# Action 3: GitHub Actions Variables (gh CLI)
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "Checking GitHub CLI (gh)..." -ForegroundColor Green
$ghAvailable = $false
if (Get-Command gh -ErrorAction SilentlyContinue) {
    try {
        $null = gh auth status 2>&1
        if ($LASTEXITCODE -eq 0) {
            $ghAvailable = $true
        }
    } catch {}
}

$setGhVars = $false
if ($ghAvailable -and $isInteractive) {
    $ghConfirm = Read-Host "Set GitHub Actions variables now via gh CLI? (y/N)"
    if ($ghConfirm -match '^[yY]$') {
        $setGhVars = $true
    }
}

if ($setGhVars) {
    Write-Host "Setting GitHub Actions variables on $GithubOrg/online-boutique-app..." -ForegroundColor Cyan
    gh variable set AWS_ACCOUNT_ID --body "$AwsAccountId" --repo "$GithubOrg/online-boutique-app"
    gh variable set AWS_REGION --body "$AwsRegion" --repo "$GithubOrg/online-boutique-app"
    gh variable set IAM_USERNAME --body "$IamUsername" --repo "$GithubOrg/online-boutique-app"
    gh variable set CONFIG_REPO_BRANCH --body "$targetBranch" --repo "$GithubOrg/online-boutique-app"
    Write-Host "GitHub Actions variables set successfully." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "GitHub Actions Variables:" -ForegroundColor Cyan
    Write-Host "Configure the following variables in GitHub (or run commands via gh CLI):"
    Write-Host "  gh variable set AWS_ACCOUNT_ID --body `"$AwsAccountId`" --repo `"$GithubOrg/online-boutique-app`""
    Write-Host "  gh variable set AWS_REGION --body `"$AwsRegion`" --repo `"$GithubOrg/online-boutique-app`""
    Write-Host "  gh variable set IAM_USERNAME --body `"$IamUsername`" --repo `"$GithubOrg/online-boutique-app`""
    Write-Host "  gh variable set CONFIG_REPO_BRANCH --body `"$targetBranch`" --repo `"$GithubOrg/online-boutique-app`""
}

# -----------------------------------------------------------------------------
# Action 4: Next Steps
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host "   Setup Complete -- Next Steps" -ForegroundColor Cyan
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host "1. Bootstrap S3 Backend:"
Write-Host "     cd $AppDir\terraform-aws\global\s3-backend"
Write-Host "     terraform init"
Write-Host "     terraform apply -auto-approve"
Write-Host "     cp backend.tf.example backend.tf"
Write-Host "     # Fill in bucket name and region in backend.tf, then migrate state:"
Write-Host "     terraform init -migrate-state"
Write-Host ""
Write-Host "2. Provision GitHub Actions OIDC Provider & Roles:"
Write-Host "     cd $AppDir\terraform-aws\global\github-oidc"
Write-Host "     terraform init -backend-config=backend.hcl"
Write-Host "     terraform apply -var `"github_org=$GithubOrg`" -auto-approve"
Write-Host ""
Write-Host "3. Provision Global ECR Repositories:"
Write-Host "     cd $AppDir\terraform-aws\global\ecr"
Write-Host "     terraform init -backend-config=backend.hcl"
Write-Host "     terraform apply -auto-approve"
Write-Host ""
Write-Host "4. Deploy Environment Infrastructure ($TargetEnv):"
Write-Host "     cd $AppDir\terraform-aws\environments\$TargetEnv"
Write-Host "     terraform init -backend-config=backend.hcl"
Write-Host "     terraform apply"
Write-Host ""
Write-Host "5. Configure kubectl:"
Write-Host "     aws eks update-kubeconfig --region $AwsRegion --name online-boutique-$TargetEnv"
Write-Host "     kubectl get nodes"
Write-Host ""
Write-Host "6. Update Redis Endpoint & Push Config Branch:"
Write-Host "     # Update REDIS_ADDR (from 'terraform output -raw redis_connection_string') in overlays/$TargetEnv/env.properties"
Write-Host "     cd `"$ConfigDir`""
Write-Host "     git checkout `"$targetBranch`""
Write-Host "     git add `"overlays/$TargetEnv/env.properties`""
Write-Host "     git commit -m `"chore: configure $TargetEnv environment values`""
Write-Host "     git push -u origin `"$targetBranch`""
Write-Host "     (Push deploy/$TargetEnv BEFORE ArgoCD sync so ArgoCD can read the branch on GitHub!)"
Write-Host "     (NEVER merge or push real environment values to the 'main' branch!)"
Write-Host ""
Write-Host "7. Install ArgoCD & Core Controllers:"
Write-Host "     helm repo add argo https://argoproj.github.io/argo-helm"
Write-Host "     helm repo update"
Write-Host "     helm install argocd argo/argo-cd -n argocd --create-namespace -f `"$ConfigDir\argocd\install\values.yaml`""
Write-Host "     # Apply aws-lb-controller & cluster-autoscaler applications (see deploy runbook)"
Write-Host "     kubectl wait --for=condition=available deployment/cluster-autoscaler-aws-cluster-autoscaler -n kube-system --timeout=180s"
Write-Host ""
Write-Host "8. Install Istio Service Mesh & Label Namespace:"
Write-Host "     istioctl install --set profile=default -y"
Write-Host "     kubectl create namespace online-boutique --dry-run=client -o yaml | kubectl apply -f -"
Write-Host "     kubectl label namespace online-boutique istio-injection=enabled --overwrite"
Write-Host ""
Write-Host "9. Bootstrap ArgoCD Applications in Config Repo:"
Write-Host "     cd `"$ConfigDir`""
Write-Host "     `$env:GITHUB_ORG=`"$GithubOrg`"; `$env:AWS_ACCOUNT_ID=`"$AwsAccountId`"; `$env:AWS_REGION=`"$AwsRegion`"; .\scripts\bootstrap-argocd.ps1 -Env `"$TargetEnv`""
Write-Host ""
Write-Host "10. Configure GitHub Repository Secrets (in $GithubOrg/online-boutique-app):"
Write-Host "     - CONFIG_REPO_TOKEN : GitHub PAT (classic) with 'repo' scope (required for CI to push image tags)"
Write-Host "     - SONAR_TOKEN       : SonarCloud token (optional; CI skips SAST analysis if unset)"
Write-Host ""
Write-Host "NOTE: Refer to devops/runbooks/deploy.md for complete step-by-step commands and details."
Write-Host "=====================================================================" -ForegroundColor Cyan
