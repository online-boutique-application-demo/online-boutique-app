#!/usr/bin/env bash
# =============================================================================
# setup.sh — Automated Placeholder Replacement Script
# Replaces placeholders across online-boutique-app and online-boutique-config
# Compatible with both GNU sed (Linux) and BSD sed (macOS)
# =============================================================================

set -euo pipefail

# Determine repository root directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="$(cd "${APP_DIR}/../online-boutique-config" 2>/dev/null && pwd || echo "")"

# --- Error Checking: Directory Validation ---
if [ -z "$CONFIG_DIR" ] || [ ! -d "$CONFIG_DIR" ]; then
  echo "Error: Directory 'online-boutique-config' not found at:"
  echo "  ${APP_DIR}/../online-boutique-config"
  echo ""
  echo "Please make sure both repositories are cloned side by side:"
  echo "  <workspace>/"
  echo "  ├── online-boutique-app/"
  echo "  └── online-boutique-config/"
  exit 1
fi

echo "====================================================================="
echo "   Online Boutique — Automated Setup & Configuration Script"
echo "====================================================================="
echo "App Directory:    ${APP_DIR}"
echo "Config Directory: ${CONFIG_DIR}"
echo "====================================================================="
echo ""

# --- Helper: Portable In-Place sed ---
sedi() {
  local pattern="$1"
  local replacement="$2"
  local file="$3"

  # Escape backslashes, ampersands, and pipes in replacement
  local safe_replacement
  safe_replacement=$(printf '%s\n' "$replacement" | sed -e 's/[\\&|]/\\&/g')

  if [ "$(uname)" = "Darwin" ]; then
    sed -i '' "s|${pattern}|${safe_replacement}|g" "$file"
  else
    sed -i "s|${pattern}|${safe_replacement}|g" "$file"
  fi
}

# --- Interactive Prompts ---

# 1. AWS Account ID (12 digits)
while true; do
  read -r -p "Enter AWS Account ID (12 digits): " AWS_ACCOUNT_ID
  if [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    break
  else
    echo "  [!] Error: AWS Account ID must be exactly 12 numeric digits (e.g., 123456789012)."
  fi
done

# 2. AWS Region
read -r -p "Enter AWS Region [ap-southeast-1]: " AWS_REGION
AWS_REGION="${AWS_REGION:-ap-southeast-1}"

# 3. IAM Username
while true; do
  read -r -p "Enter IAM Username (for cluster admin access): " IAM_USERNAME
  if [ -n "$IAM_USERNAME" ]; then
    break
  else
    echo "  [!] Error: IAM Username cannot be empty."
  fi
done

# 4. GitHub Organization or Username
while true; do
  read -r -p "Enter GitHub Organization or Username: " GITHUB_ORG
  if [ -n "$GITHUB_ORG" ]; then
    break
  else
    echo "  [!] Error: GitHub Organization/Username cannot be empty."
  fi
done

# 5. GitHub Username for README attribution
read -r -p "Enter GitHub Username for README attribution [${GITHUB_ORG}]: " GITHUB_USERNAME
GITHUB_USERNAME="${GITHUB_USERNAME:-$GITHUB_ORG}"

# 6. Contact Email
read -r -p "Enter contact email for README (optional, press Enter to skip): " USER_EMAIL

# 7. EKS Cluster Names
read -r -p "Enter Dev EKS Cluster Name [online-boutique-dev]: " EKS_CLUSTER_DEV
EKS_CLUSTER_DEV="${EKS_CLUSTER_DEV:-online-boutique-dev}"

read -r -p "Enter Staging EKS Cluster Name [online-boutique-staging]: " EKS_CLUSTER_STAGING
EKS_CLUSTER_STAGING="${EKS_CLUSTER_STAGING:-online-boutique-staging}"

# 8. Redis Endpoint
read -r -p "Enter Redis Endpoint (optional, press Enter to skip for later): " REDIS_ENDPOINT

# 9. Grafana Admin Password
read -r -p "Enter Grafana Admin Password [admin]: " GRAFANA_ADMIN_PASSWORD
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"

# 10. SonarCloud Org & Project Key
read -r -p "Enter SonarCloud Organization (optional, press Enter to skip): " SONAR_ORG
read -r -p "Enter SonarCloud Project Key (optional, press Enter to skip): " SONAR_PROJECT_KEY

echo ""
echo "Replacing placeholders across both repositories..."
echo "---------------------------------------------------------------------"

# --- Discover Target Files ---
# Search in app and config repos, excluding git, terraform state/cache, setup scripts and SETUP.md
TARGET_FILES=()
while IFS= read -r file; do
  TARGET_FILES+=("$file")
done < <(find "$APP_DIR" "$CONFIG_DIR" -type f \
  \( -name "*.tf" -o -name "*.tfvars" -o -name "*.example" -o -name "*.yaml" -o -name "*.yml" -o -name "*.properties" -o -name "*.md" -o -name "CODEOWNERS" \) \
  ! -path "*/.git/*" \
  ! -path "*/.terraform/*" \
  ! -path "*/node_modules/*" \
  ! -path "*/scripts/setup.*" \
  ! -path "*/SETUP.md")

MODIFIED_FILES=()

# --- Process Replacements ---
for file in "${TARGET_FILES[@]}"; do
  # Check if file contains any known placeholder pattern
  if grep -q -E '<(AWS_ACCOUNT_ID|YOUR_AWS_ACCOUNT_ID|AWS_REGION|YOUR_IAM_USERNAME|GITHUB_ORG|YOUR_GITHUB_ORG|YOUR_GITHUB_USERNAME|YOUR_EMAIL|GRAFANA_ADMIN_PASSWORD|EKS_CLUSTER_NAME|REDIS_ENDPOINT|YOUR_SONAR_ORG|YOUR_SONAR_PROJECT_KEY)>' "$file" 2>/dev/null; then

    # Compute checksum before modifications
    orig_sum=$(cksum "$file" 2>/dev/null | awk '{print $1}')

    # Apply global replacements
    sedi '<AWS_ACCOUNT_ID>' "$AWS_ACCOUNT_ID" "$file"
    sedi '<YOUR_AWS_ACCOUNT_ID>' "$AWS_ACCOUNT_ID" "$file"
    sedi '<AWS_REGION>' "$AWS_REGION" "$file"
    sedi '<YOUR_IAM_USERNAME>' "$IAM_USERNAME" "$file"
    sedi '<GITHUB_ORG>' "$GITHUB_ORG" "$file"
    sedi '<YOUR_GITHUB_ORG>' "$GITHUB_ORG" "$file"
    sedi '<YOUR_GITHUB_USERNAME>' "$GITHUB_USERNAME" "$file"
    sedi '<GRAFANA_ADMIN_PASSWORD>' "$GRAFANA_ADMIN_PASSWORD" "$file"

    if [ -n "$USER_EMAIL" ]; then
      sedi '<YOUR_EMAIL>' "$USER_EMAIL" "$file"
    fi

    if [ -n "$REDIS_ENDPOINT" ]; then
      sedi '<REDIS_ENDPOINT>' "$REDIS_ENDPOINT" "$file"
    fi

    if [ -n "$SONAR_ORG" ]; then
      sedi '<YOUR_SONAR_ORG>' "$SONAR_ORG" "$file"
    fi

    if [ -n "$SONAR_PROJECT_KEY" ]; then
      sedi '<YOUR_SONAR_PROJECT_KEY>' "$SONAR_PROJECT_KEY" "$file"
    fi

    # Staging vs Dev EKS Cluster Name
    if echo "$file" | grep -q "/staging/"; then
      sedi '<EKS_CLUSTER_NAME>' "$EKS_CLUSTER_STAGING" "$file"
    else
      sedi '<EKS_CLUSTER_NAME>' "$EKS_CLUSTER_DEV" "$file"
    fi

    # Compute checksum after modifications
    new_sum=$(cksum "$file" 2>/dev/null | awk '{print $1}')
    if [ "$orig_sum" != "$new_sum" ]; then
      MODIFIED_FILES+=("$file")
    fi
  fi
done

# --- Output Summary ---
echo ""
echo "====================================================================="
echo "   Modified Files (${#MODIFIED_FILES[@]} files updated)"
echo "====================================================================="
if [ ${#MODIFIED_FILES[@]} -eq 0 ]; then
  echo "No files modified. All placeholders may have already been replaced."
else
  for mod_file in "${MODIFIED_FILES[@]}"; do
    # Display relative path from parent workspace for readability
    rel_path=$(echo "$mod_file" | sed "s|$(dirname "$APP_DIR")/||")
    echo "  [MODIFIED] ${rel_path}"
  done
fi

echo ""
echo "====================================================================="
echo "   Configuration Summary"
echo "====================================================================="
echo "  AWS Account ID:         ${AWS_ACCOUNT_ID}"
echo "  AWS Region:             ${AWS_REGION}"
echo "  IAM Username:           ${IAM_USERNAME}"
echo "  GitHub Org / Owner:     ${GITHUB_ORG}"
echo "  GitHub Username:        ${GITHUB_USERNAME}"
echo "  Contact Email:          ${USER_EMAIL:-[Skipped]}"
echo "  Dev EKS Cluster:        ${EKS_CLUSTER_DEV}"
echo "  Staging EKS Cluster:    ${EKS_CLUSTER_STAGING}"
echo "  Redis Endpoint:         ${REDIS_ENDPOINT:-[Skipped - to be configured after ElastiCache provision]}"
echo "  Grafana Admin Password: ${GRAFANA_ADMIN_PASSWORD}"
echo "  SonarCloud Org:         ${SONAR_ORG:-[Skipped]}"
echo "  SonarCloud Project Key: ${SONAR_PROJECT_KEY:-[Skipped]}"
echo "====================================================================="
echo ""
echo "Next Steps:"
echo "1. Verify changes with 'git diff' in both repositories."
echo "2. Commit and push changes if desired."
echo "3. Follow SETUP.md Step 5 to bootstrap the S3 backend:"
echo "     cd terraform-aws/global/s3-backend"
echo "     cp backend.tf.example backend.tf"
echo "     terraform init && terraform apply"
echo "====================================================================="
