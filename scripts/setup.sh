#!/usr/bin/env bash
# =============================================================================
# setup.sh -- Automated Setup & Local Configuration Script
# Generates local gitignored configuration files and configures config repo branch.
# Does NOT commit or push any changes.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "====================================================================="
echo "   Online Boutique -- Automated Setup & Configuration Script"
echo "====================================================================="
echo "App Directory: ${APP_DIR}"
echo "====================================================================="
echo ""

# Determine if all required variables are supplied via environment variables
IS_ALL_SET=false
if [ -n "${AWS_ACCOUNT_ID:-}" ] && [ -n "${AWS_REGION:-}" ] && [ -n "${GITHUB_ORG:-}" ] && [ -n "${IAM_USERNAME:-}" ]; then
  IS_ALL_SET=true
fi

if [ "$IS_ALL_SET" = true ]; then
  # Non-interactive mode (all required inputs passed via env vars)
  if ! [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    echo "Error: Invalid AWS_ACCOUNT_ID='$AWS_ACCOUNT_ID'. Must be exactly 12 numeric digits." >&2
    exit 1
  fi
  CONFIG_REPO_PATH="${CONFIG_REPO_PATH:-../online-boutique-config}"
  REDIS_ENDPOINT="${REDIS_ENDPOINT:-}"
  ENV="${ENV:-dev}"
elif [ -t 0 ]; then
  # Interactive mode: prompt for missing values
  # 1. AWS Account ID (12 digits)
  if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    while true; do
      read -r -p "Enter AWS Account ID (12 digits): " AWS_ACCOUNT_ID
      if [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
        break
      else
        echo "  [!] Error: AWS Account ID must be exactly 12 numeric digits (e.g., 123456789012)."
      fi
    done
  elif ! [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    echo "Error: Invalid AWS_ACCOUNT_ID='$AWS_ACCOUNT_ID'. Must be exactly 12 numeric digits." >&2
    exit 1
  fi

  # 2. AWS Region
  if [ -z "${AWS_REGION:-}" ]; then
    read -r -p "Enter AWS Region [ap-southeast-1]: " AWS_REGION_INPUT
    AWS_REGION="${AWS_REGION_INPUT:-ap-southeast-1}"
  fi

  # 3. GitHub Organization or Username
  if [ -z "${GITHUB_ORG:-}" ]; then
    while true; do
      read -r -p "Enter GitHub Organization or Username: " GITHUB_ORG
      if [ -n "$GITHUB_ORG" ]; then
        break
      else
        echo "  [!] Error: GitHub Organization/Username cannot be empty."
      fi
    done
  fi

  # 4. IAM Username
  if [ -z "${IAM_USERNAME:-}" ]; then
    while true; do
      read -r -p "Enter IAM Username (for cluster admin access): " IAM_USERNAME
      if [ -n "$IAM_USERNAME" ]; then
        break
      else
        echo "  [!] Error: IAM Username cannot be empty."
      fi
    done
  fi

  # 5. Config Repository Path
  if [ -z "${CONFIG_REPO_PATH:-}" ]; then
    read -r -p "Enter path to online-boutique-config [../online-boutique-config]: " CONFIG_INPUT
    CONFIG_REPO_PATH="${CONFIG_INPUT:-../online-boutique-config}"
  fi

  # 6. Redis Endpoint (optional)
  if [ -z "${REDIS_ENDPOINT+x}" ]; then
    read -r -p "Enter Redis Endpoint (optional, press Enter to skip): " REDIS_ENDPOINT
  fi

  # 7. Environment (default dev)
  if [ -z "${ENV:-}" ]; then
    read -r -p "Enter Target Environment (dev/staging) [dev]: " ENV_INPUT
    ENV="${ENV_INPUT:-dev}"
  fi
else
  # Non-interactive mode with missing variables
  if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    echo "Error: Required environment variable AWS_ACCOUNT_ID is not set." >&2
    exit 1
  fi
  if ! [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    echo "Error: Invalid AWS_ACCOUNT_ID='$AWS_ACCOUNT_ID'. Must be exactly 12 numeric digits." >&2
    exit 1
  fi
  AWS_REGION="${AWS_REGION:-ap-southeast-1}"
  if [ -z "${GITHUB_ORG:-}" ]; then
    echo "Error: Required environment variable GITHUB_ORG is not set." >&2
    exit 1
  fi
  if [ -z "${IAM_USERNAME:-}" ]; then
    echo "Error: Required environment variable IAM_USERNAME is not set." >&2
    exit 1
  fi
  CONFIG_REPO_PATH="${CONFIG_REPO_PATH:-../online-boutique-config}"
  REDIS_ENDPOINT="${REDIS_ENDPOINT:-}"
  ENV="${ENV:-dev}"
fi

# Resolve Config Directory
if [[ "$CONFIG_REPO_PATH" = /* ]]; then
  CONFIG_DIR="$CONFIG_REPO_PATH"
else
  CONFIG_DIR="$(cd "${APP_DIR}/${CONFIG_REPO_PATH}" 2>/dev/null && pwd || echo "")"
fi

if [ -z "$CONFIG_DIR" ] || [ ! -d "$CONFIG_DIR" ]; then
  echo "Error: Directory '$CONFIG_REPO_PATH' not found at '${APP_DIR}/${CONFIG_REPO_PATH}'." >&2
  exit 1
fi

if [ ! -d "${CONFIG_DIR}/.git" ]; then
  echo "Error: '$CONFIG_DIR' is not a git repository." >&2
  exit 1
fi

echo ""
echo "====================================================================="
echo "   Configuration Parameters"
echo "====================================================================="
echo "  AWS Account ID:     ${AWS_ACCOUNT_ID}"
echo "  AWS Region:         ${AWS_REGION}"
echo "  GitHub Org:         ${GITHUB_ORG}"
echo "  IAM Username:       ${IAM_USERNAME}"
echo "  Target Environment: ${ENV}"
echo "  Config Repo Path:   ${CONFIG_DIR}"
echo "  Redis Endpoint:     ${REDIS_ENDPOINT:-[Not provided - placeholder will be kept]}"
echo "====================================================================="
echo ""

# -----------------------------------------------------------------------------
# Action 1: Generate gitignored local files ONLY
# -----------------------------------------------------------------------------
echo "Generating gitignored local Terraform files..."

TF_BACKEND_DIRS=(
  "${APP_DIR}/terraform-aws/environments/dev"
  "${APP_DIR}/terraform-aws/environments/staging"
  "${APP_DIR}/terraform-aws/global/ecr"
  "${APP_DIR}/terraform-aws/global/github-oidc"
)

for tf_dir in "${TF_BACKEND_DIRS[@]}"; do
  if [ ! -d "$tf_dir" ]; then
    echo "Error: Directory '$tf_dir' does not exist." >&2
    exit 1
  fi
  backend_file="${tf_dir}/backend.hcl"
  cat <<EOF > "$backend_file"
bucket = "online-boutique-tfstate-${AWS_ACCOUNT_ID}"
region = "${AWS_REGION}"
EOF

  rel_backend_file="${backend_file#${APP_DIR}/}"
  # Verify gitignored
  if ! git -C "$APP_DIR" check-ignore -q "$rel_backend_file"; then
    echo "Error: Generated file '$rel_backend_file' is NOT ignored by git! Aborting to prevent credential leakage." >&2
    rm -f "$backend_file"
    exit 1
  fi
  echo "  [CREATED] ${rel_backend_file} (gitignored)"
done

# Generate terraform.tfvars in environments/<env>
ENV_DIR="${APP_DIR}/terraform-aws/environments/${ENV}"
if [ ! -d "$ENV_DIR" ]; then
  echo "Error: Environment directory '$ENV_DIR' does not exist." >&2
  exit 1
fi

TFVARS_EXAMPLE="${ENV_DIR}/terraform.tfvars.example"
TFVARS_FILE="${ENV_DIR}/terraform.tfvars"
if [ ! -f "$TFVARS_EXAMPLE" ]; then
  echo "Error: Example file '$TFVARS_EXAMPLE' not found." >&2
  exit 1
fi

# Portable sed without -i, redirecting to target file
sed -e "s|<AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" \
    -e "s|<IAM_USERNAME>|${IAM_USERNAME}|g" \
    -e "s|aws_region[[:space:]]*=[[:space:]]*\"[^\"]*\"|aws_region   = \"${AWS_REGION}\"|g" \
    "$TFVARS_EXAMPLE" > "$TFVARS_FILE"

rel_tfvars_file="${TFVARS_FILE#${APP_DIR}/}"
# Verify gitignored
if ! git -C "$APP_DIR" check-ignore -q "$rel_tfvars_file"; then
  echo "Error: Generated file '$rel_tfvars_file' is NOT ignored by git! Aborting to prevent credential leakage." >&2
  rm -f "$TFVARS_FILE"
  exit 1
fi
echo "  [CREATED] ${rel_tfvars_file} (gitignored)"

# -----------------------------------------------------------------------------
# Action 2: Config repo configuration
# -----------------------------------------------------------------------------
echo ""
echo "Configuring config repository at: ${CONFIG_DIR}..."

TARGET_BRANCH="deploy/${ENV}"
CURRENT_BRANCH="$(git -C "$CONFIG_DIR" rev-parse --abbrev-ref HEAD)"

if [ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]; then
  if git -C "$CONFIG_DIR" show-ref --verify --quiet "refs/heads/${TARGET_BRANCH}"; then
    git -C "$CONFIG_DIR" checkout "$TARGET_BRANCH"
  else
    git -C "$CONFIG_DIR" checkout -b "$TARGET_BRANCH"
  fi
  CURRENT_BRANCH="$(git -C "$CONFIG_DIR" rev-parse --abbrev-ref HEAD)"
fi

if [ "$CURRENT_BRANCH" = "main" ]; then
  echo "Error: Config repository is on branch 'main'. Refusing to write real environment values to main branch." >&2
  exit 1
fi

if [ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]; then
  echo "Error: Failed to switch to branch '$TARGET_BRANCH' (currently on '$CURRENT_BRANCH')." >&2
  exit 1
fi

OVERLAY_DIR="${CONFIG_DIR}/overlays/${ENV}"
if [ ! -d "$OVERLAY_DIR" ]; then
  echo "Error: Overlay directory '$OVERLAY_DIR' does not exist." >&2
  exit 1
fi

ENV_PROPERTIES_FILE="${OVERLAY_DIR}/env.properties"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

if [ -n "$REDIS_ENDPOINT" ]; then
  if [[ "$REDIS_ENDPOINT" == *:* ]]; then
    REDIS_ADDR="$REDIS_ENDPOINT"
  else
    REDIS_ADDR="${REDIS_ENDPOINT}:6379"
  fi
else
  REDIS_ADDR="<REDIS_ENDPOINT>:6379"
fi

cat <<EOF > "$ENV_PROPERTIES_FILE"
# Environment configuration for ${ENV} overlay
# IMPORTANT: In the public repository, keep placeholder values.
# Real environment-specific values must ONLY be populated on the ${TARGET_BRANCH} branch.

ECR_REGISTRY=${ECR_REGISTRY}
REDIS_ADDR=${REDIS_ADDR}
EOF

echo "  [UPDATED] ${ENV_PROPERTIES_FILE#${CONFIG_DIR}/} (on branch ${TARGET_BRANCH})"

if [ -z "$REDIS_ENDPOINT" ]; then
  echo ""
  echo "  [WARNING] REDIS_ENDPOINT was not set. Left placeholder '<REDIS_ENDPOINT>:6379' in overlays/${ENV}/env.properties."
  echo "            After provisioning infrastructure with 'terraform apply', update REDIS_ADDR using"
  echo "            the output 'redis_connection_string' from terraform-aws/environments/${ENV}."
fi

echo ""
echo "  [IMPORTANT] Config changes were written on branch '${TARGET_BRANCH}'."
echo "              Commit and push ONLY to '${TARGET_BRANCH}'. NEVER commit real values to 'main'!"
echo "              (No automatic commits were made)."

# -----------------------------------------------------------------------------
# Action 3: GitHub Actions Variables (gh CLI)
# -----------------------------------------------------------------------------
echo ""
echo "Checking GitHub CLI (gh)..."
GH_AVAILABLE=false
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    GH_AVAILABLE=true
  fi
fi

SET_GH_VARS=false
if [ "$GH_AVAILABLE" = true ] && [ -t 0 ] && [ "$IS_ALL_SET" = false ]; then
  read -r -p "Set GitHub Actions variables now via gh CLI? (y/N): " GH_CONFIRM
  if [[ "$GH_CONFIRM" =~ ^[yY]$ ]]; then
    SET_GH_VARS=true
  fi
fi

if [ "$SET_GH_VARS" = true ]; then
  echo "Setting GitHub Actions variables on ${GITHUB_ORG}/online-boutique-app..."
  gh variable set AWS_ACCOUNT_ID --body "$AWS_ACCOUNT_ID" --repo "${GITHUB_ORG}/online-boutique-app"
  gh variable set AWS_REGION --body "$AWS_REGION" --repo "${GITHUB_ORG}/online-boutique-app"
  gh variable set IAM_USERNAME --body "$IAM_USERNAME" --repo "${GITHUB_ORG}/online-boutique-app"
  gh variable set CONFIG_REPO_BRANCH --body "${TARGET_BRANCH}" --repo "${GITHUB_ORG}/online-boutique-app"
  echo "GitHub Actions variables set successfully."
else
  echo ""
  echo "GitHub Actions Variables:"
  echo "Configure the following variables in GitHub (or run commands via gh CLI):"
  echo "  gh variable set AWS_ACCOUNT_ID --body \"${AWS_ACCOUNT_ID}\" --repo \"${GITHUB_ORG}/online-boutique-app\""
  echo "  gh variable set AWS_REGION --body \"${AWS_REGION}\" --repo \"${GITHUB_ORG}/online-boutique-app\""
  echo "  gh variable set IAM_USERNAME --body \"${IAM_USERNAME}\" --repo \"${GITHUB_ORG}/online-boutique-app\""
  echo "  gh variable set CONFIG_REPO_BRANCH --body \"${TARGET_BRANCH}\" --repo \"${GITHUB_ORG}/online-boutique-app\""
fi

# -----------------------------------------------------------------------------
# Action 4: Next Steps
# -----------------------------------------------------------------------------
echo ""
echo "====================================================================="
echo "   Setup Complete -- Next Steps"
echo "====================================================================="
echo "1. Bootstrap S3 Backend:"
echo "     cd ${APP_DIR}/terraform-aws/global/s3-backend"
echo "     terraform init"
echo "     terraform apply -auto-approve"
echo "     cp backend.tf.example backend.tf"
echo "     # Fill in bucket name and region in backend.tf, then migrate state:"
echo "     terraform init -migrate-state"
echo ""
echo "2. Provision GitHub Actions OIDC Provider & Roles:"
echo "     cd ${APP_DIR}/terraform-aws/global/github-oidc"
echo "     terraform init -backend-config=backend.hcl"
echo "     terraform apply -var \"github_org=${GITHUB_ORG}\" -auto-approve"
echo ""
echo "3. Provision Global ECR Repositories:"
echo "     cd ${APP_DIR}/terraform-aws/global/ecr"
echo "     terraform init -backend-config=backend.hcl"
echo "     terraform apply -auto-approve"
echo ""
echo "4. Deploy Environment Infrastructure (${ENV}):"
echo "     cd ${APP_DIR}/terraform-aws/environments/${ENV}"
echo "     terraform init -backend-config=backend.hcl"
echo "     terraform apply"
echo "     # Note the 'redis_connection_string' output."
echo "     # If REDIS_ENDPOINT was skipped, update overlays/${ENV}/env.properties in config repo now."
echo ""
echo "5. Configure kubectl:"
echo "     aws eks update-kubeconfig --region ${AWS_REGION} --name online-boutique-${ENV}"
echo "     kubectl get nodes"
echo ""
echo "6. Install ArgoCD on the EKS Cluster:"
echo "     helm repo add argo https://argoproj.github.io/argo-helm"
echo "     helm repo update"
echo "     helm install argocd argo/argo-cd -n argocd --create-namespace -f \"${CONFIG_DIR}/argocd/install/values.yaml\""
echo ""
echo "7. Bootstrap ArgoCD Applications in Config Repo:"
echo "     cd \"${CONFIG_DIR}\""
echo "     GITHUB_ORG=\"${GITHUB_ORG}\" AWS_ACCOUNT_ID=\"${AWS_ACCOUNT_ID}\" AWS_REGION=\"${AWS_REGION}\" ./scripts/bootstrap-argocd.sh \"${ENV}\""
echo ""
echo "8. Configure GitHub Repository Secrets (in ${GITHUB_ORG}/online-boutique-app):"
echo "     - CONFIG_REPO_TOKEN : GitHub PAT (classic) with 'repo' scope (required for CI to push image tags)"
echo "     - SONAR_TOKEN       : SonarCloud token (optional; CI skips SAST analysis if unset)"
echo ""
echo "9. Commit and Push Config Repo Changes:"
echo "     cd \"${CONFIG_DIR}\""
echo "     git add \"overlays/${ENV}/env.properties\""
echo "     git commit -m \"chore: configure ${ENV} environment values\""
echo "     git push -u origin \"${TARGET_BRANCH}\""
echo "     (NEVER merge or push real environment values to the 'main' branch!)"
echo "====================================================================="
