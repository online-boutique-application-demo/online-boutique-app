# Setup Guide — Online Boutique DevOps Project

This guide provides comprehensive, step-by-step instructions for configuring, provisioning, and deploying the **Google Online Boutique** microservices application on **Amazon Web Services (AWS)** using Terraform IaC, GitHub Actions CI/CD, and ArgoCD GitOps.

> [!WARNING]
> **CRITICAL SECURITY REQUIREMENT: NEVER COMMIT REAL ENVIRONMENT VALUES TO `main`**
> The `main` branch across both repositories (`online-boutique-app` and `online-boutique-config`) is maintained strictly as an **account-agnostic, public template**.
> All real environment values (such as AWS Account ID, IAM usernames, ECR registries, and Redis endpoints) must **ONLY** reside in gitignored local files (`backend.hcl`, `terraform.tfvars`) and dedicated deployment branches (e.g., `deploy/dev`, `deploy/staging`) in `online-boutique-config`.
> **Never commit or push real environment values to `main` or public forks.**

---

## Architecture & Repository Model

The solution uses a two-repository GitOps structure:

```text
online-boutique-workspace/
├── online-boutique-app/        # Source code, Dockerfiles, Terraform IaC, GitHub Actions CI
└── online-boutique-config/     # Kubernetes manifests, Kustomize overlays, ArgoCD Application templates
```

### GitOps Branching Model
- **`main` Branch (Public Template):**
  - Contains generic Kubernetes manifests and Kustomize overlays.
  - Image paths use generic placeholders: `REGISTRY/online-boutique/<service>:latest`.
  - `overlays/<env>/env.properties` contains standardized placeholders only.
- **`deploy/<env>` Branches (Live Deployments, e.g. `deploy/dev`):**
  - Active cluster environments track their respective `deploy/<env>` branch.
  - Only `overlays/<env>/env.properties` is populated with real values (`ECR_REGISTRY`, `REDIS_ADDR`).
  - Kustomize `replacements` and `configMapGenerator` dynamically inject real registry URLs and Redis connection strings into Kubernetes Deployments at render time.
  - GitHub Actions CI workflows automatically commit updated image tags to `CONFIG_REPO_BRANCH` (`deploy/dev`).

---

## Prerequisites

Before beginning, ensure you have an active **AWS Account** with administrative privileges and a **GitHub Account**. Verify the following CLI tools are installed on your machine:

| Tool | Minimum Version | Verification Command | Notes |
|---|---|---|---|
| **AWS CLI** | `v2.x` | `aws --version` | Configured with Administrator or DevOps credentials |
| **Terraform** | `>= 1.10.0` | `terraform -version` | Supports S3 native state locking (`use_lockfile = true`) |
| **kubectl** | `>= 1.28.0` | `kubectl version --client` | Kubernetes CLI |
| **Helm** | `>= 3.x` | `helm version` | Package manager for Kubernetes (ArgoCD installation) |
| **ArgoCD CLI / Server** | `>= 2.9.0` | `argocd version` | Required for inline Kustomize replacements and patches |
| **Git** | `>= 2.x` | `git --version` | Version control |
| **GitHub CLI (`gh`)** | `>= 2.x` (Optional) | `gh --version` | Used to configure repository variables automatically |

---

## Step 1: Fork & Clone Repositories

1. Fork both repositories on GitHub to your user account or organization (`<GITHUB_ORG>`):
   - `https://github.com/<GITHUB_ORG>/online-boutique-app`
   - `https://github.com/<GITHUB_ORG>/online-boutique-config`

2. Clone both repositories side by side into the same parent workspace directory:
   ```bash
   mkdir -p online-boutique-workspace
   cd online-boutique-workspace

   git clone https://github.com/<GITHUB_ORG>/online-boutique-app.git
   git clone https://github.com/<GITHUB_ORG>/online-boutique-config.git
   ```

3. Confirm directory structure:
   ```text
   online-boutique-workspace/
   ├── online-boutique-app/
   └── online-boutique-config/
   ```

---

## Step 2: Configure GitHub Repository Variables & Secrets

All CI/CD workflows authenticate with AWS using **GitHub OIDC** (OpenID Connect), eliminating the need for long-lived AWS IAM access keys.

Navigate to your `online-boutique-app` repository on GitHub: **Settings** → **Secrets and variables** → **Actions**.

### Repository Variables

Add the following under the **Variables** tab:

| Variable | Required? | Description | Example |
|---|---|---|---|
| `AWS_ACCOUNT_ID` | **Yes** | Your 12-digit AWS Account ID | `123456789012` |
| `AWS_REGION` | **Yes** | Target AWS region for infrastructure and ECR | `ap-southeast-1` or `us-east-1` |
| `IAM_USERNAME` | **Yes** | Your IAM user name for EKS cluster admin access | `devops-admin` |
| `CONFIG_REPO_BRANCH` | Optional | Branch in `online-boutique-config` that CI updates with new image tags (defaults to `main`) | `deploy/dev` |

> [!TIP]
> Retrieve your 12-digit AWS Account ID using AWS CLI:
> ```bash
> aws sts get-caller-identity --query "Account" --output text
> ```

### Repository Secrets

Add the following under the **Secrets** tab:

| Secret | Required? | Description |
|---|---|---|
| `CONFIG_REPO_TOKEN` | **Yes** | GitHub Personal Access Token (classic) with `repo` scope. Allows CI workflows to push updated image tags to `online-boutique-config`. |
| `SONAR_TOKEN` | Optional | SonarCloud project analysis token for static application security testing (SAST). If omitted, the SonarCloud job in CI automatically skips without failing the pipeline. |

#### Generating `CONFIG_REPO_TOKEN`:
1. In GitHub, go to **Settings** → **Developer Settings** → **Personal Access Tokens** → **Tokens (classic)**.
2. Click **Generate new token (classic)**.
3. Set name to `online-boutique-gitops-sync`.
4. Select scope: `repo` (Full control of private repositories).
5. Copy the generated token and save as `CONFIG_REPO_TOKEN` under GitHub Actions Secrets.

#### Optional SonarCloud SAST Configuration:
If you use SonarCloud for code analysis:
1. Open [sonar-project.properties](sonar-project.properties).
2. Set `sonar.organization=<SONAR_ORG>` and `sonar.projectKey=<SONAR_PROJECT_KEY>`.
3. Add `SONAR_TOKEN` to GitHub Secrets.

---

## Step 3: Run the Automated Setup Script

The automated setup script generates local gitignored configuration files and prepares the GitOps deployment branch without touching tracked files.

### What the Script Performs:
1. **Generates gitignored `backend.hcl` files** for Terraform partial backend in:
   - `terraform-aws/environments/dev/backend.hcl`
   - `terraform-aws/environments/staging/backend.hcl`
   - `terraform-aws/global/ecr/backend.hcl`
   - `terraform-aws/global/github-oidc/backend.hcl`
2. **Generates gitignored `terraform.tfvars`** in `terraform-aws/environments/<env>` from `terraform.tfvars.example`, substituting `<AWS_ACCOUNT_ID>`, `<IAM_USERNAME>`, and `<AWS_REGION>`.
3. **Verifies via `git check-ignore`** that every generated file is strictly gitignored before proceeding, preventing accidental credential exposure.
4. **Configures `online-boutique-config`**: Ensures branch `deploy/<env>` exists, switches to it, and writes `overlays/<env>/env.properties` with real `ECR_REGISTRY` and `REDIS_ADDR`. It refuses to write if currently on `main`.
5. **Sets GitHub Repository Variables**: If `gh` CLI is installed and authenticated, offers to set the variables automatically.

### Running the Setup Script

#### Option A: On Linux / macOS (Bash)
```bash
cd online-boutique-app
chmod +x scripts/setup.sh

# Interactive mode:
./scripts/setup.sh

# Or non-interactive mode with environment variables:
AWS_ACCOUNT_ID="<AWS_ACCOUNT_ID>" \
AWS_REGION="<AWS_REGION>" \
GITHUB_ORG="<GITHUB_ORG>" \
IAM_USERNAME="<IAM_USERNAME>" \
./scripts/setup.sh
```

#### Option B: On Windows (PowerShell)
```powershell
cd online-boutique-app

# Interactive mode:
.\scripts\setup.ps1

# Or non-interactive mode:
.\scripts\setup.ps1 -AwsAccountId "<AWS_ACCOUNT_ID>" -AwsRegion "<AWS_REGION>" -GithubOrg "<GITHUB_ORG>" -IamUsername "<IAM_USERNAME>"
```

---

## Step 4: Step-by-Step Provisioning & Deployment Order

Provision AWS resources and deploy applications in the exact sequence below:

```text
S3 Backend Bootstrap ──► GitHub OIDC Provider ──► Global ECR Repositories ──► Dev Environment Infra ──► Install ArgoCD ──► Bootstrap Applications
```

### 1. Bootstrap Terraform S3 Backend
The S3 backend uses AWS native state locking (`use_lockfile = true`) introduced in Terraform 1.10.

1. Navigate to the backend bootstrap directory:
   ```bash
   cd terraform-aws/global/s3-backend
   ```
2. Initialize and apply with local state to provision the remote S3 bucket:
   ```bash
   terraform init
   terraform apply -auto-approve
   ```
   *Creates S3 bucket: `online-boutique-tfstate-<AWS_ACCOUNT_ID>` with AES256 encryption, bucket versioning, and public access blocks.*

3. Migrate state to the new remote S3 backend:
   - Copy `backend.tf.example` to `backend.tf`:
     ```bash
     cp backend.tf.example backend.tf
     ```
   - Update `bucket = "online-boutique-tfstate-<AWS_ACCOUNT_ID>"` and `region = "<AWS_REGION>"` in `backend.tf`.
   - Run state migration:
     ```bash
     terraform init -migrate-state
     ```

---

### 2. Provision GitHub Actions OIDC Provider & Roles
Provision IAM roles that allow GitHub Actions to securely authenticate via OIDC:

```bash
cd ../github-oidc
terraform init -backend-config=backend.hcl
terraform apply -var "github_org=<GITHUB_ORG>" -auto-approve
```
*Creates `online-boutique-github-ci` role and `online-boutique-github-terraform` role with trust policies restricted to `<GITHUB_ORG>/online-boutique-app`.*

---

### 3. Provision Global ECR Repositories
Create private Amazon ECR repositories for all 11 microservices:

```bash
cd ../ecr
terraform init -backend-config=backend.hcl
terraform apply -auto-approve
```

---

### 4. Deploy Dev Environment Infrastructure
Deploy VPC networking, Amazon EKS cluster, and Amazon ElastiCache Redis:

```bash
cd ../../environments/dev
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```
*(EKS cluster and node group provisioning typically takes 12–18 minutes).*

Upon completion, note the Terraform outputs:
- `cluster_name`: `online-boutique-dev`
- `redis_connection_string`: Endpoint formatted as `<host>:<port>`

> [!NOTE]
> If you skipped providing `REDIS_ENDPOINT` during the setup script execution, update `overlays/dev/env.properties` in `online-boutique-config` now with the output from `redis_connection_string`:
> ```properties
> REDIS_ADDR=<REDIS_ENDPOINT>:6379
> ```

---

### 5. Configure Local `kubectl` Access
Authenticate your local Kubernetes CLI with the newly created Amazon EKS cluster:

```bash
aws eks update-kubeconfig --region <AWS_REGION> --name online-boutique-dev
kubectl get nodes -o wide
```
Verify that all worker nodes report `Ready`.

---

### 6. Install ArgoCD on the EKS Cluster
Install ArgoCD using Helm and custom values:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install ArgoCD into the 'argocd' namespace
helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  -f ../../../../online-boutique-config/argocd/install/values.yaml
```

Wait until all ArgoCD pods are running:
```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
```

---

### 7. Bootstrap ArgoCD Applications & Monitoring Stack
Run the bootstrap script in `online-boutique-config` to initialize all services, Istio service mesh, and Prometheus/Grafana monitoring.

The bootstrap script performs two vital operations:
1. Prompts for `GRAFANA_ADMIN_PASSWORD` (or reads environment variable) and creates the Kubernetes Secret `grafana-admin` in namespace `monitoring`. **This password is never committed to Git.**
2. Renders all ArgoCD Application definitions in `argocd/apps/dev/*.yaml` with your `<GITHUB_ORG>`, `<AWS_ACCOUNT_ID>`, `<AWS_REGION>`, and target revision (`deploy/dev`), applying them directly to the cluster without modifying tracked Git files.

#### Run Bootstrap on Linux / macOS (Bash):
```bash
cd ../../../../online-boutique-config
export GITHUB_ORG="<GITHUB_ORG>"
export AWS_ACCOUNT_ID="<AWS_ACCOUNT_ID>"
export AWS_REGION="<AWS_REGION>"

# Optional: export GRAFANA_ADMIN_PASSWORD="YourSecurePassword"
./scripts/bootstrap-argocd.sh dev
```

#### Run Bootstrap on Windows (PowerShell):
```powershell
cd ..\..\..\..\online-boutique-config
$env:GITHUB_ORG = "<GITHUB_ORG>"
$env:AWS_ACCOUNT_ID = "<AWS_ACCOUNT_ID>"
$env:AWS_REGION = "<AWS_REGION>"

# Optional: $env:GRAFANA_ADMIN_PASSWORD = "YourSecurePassword"
.\scripts\bootstrap-argocd.ps1 -Env "dev"
```

---

### 8. Commit and Push Configuration to `deploy/<env>`
In `online-boutique-config`, commit and push your updated `overlays/dev/env.properties`:

```bash
cd online-boutique-config

# Ensure you are on the deployment branch
git checkout deploy/dev

# Commit only overlays/dev/env.properties
git add overlays/dev/env.properties
git commit -m "chore: configure dev environment values"
git push -u origin deploy/dev
```

> [!CAUTION]
> Confirm before pushing:
> ```bash
> git branch --show-current
> ```
> Output must be `deploy/dev`. **Never merge `deploy/dev` back into `main`!**

---

## Step 5: Verification & Accessing Services

### 1. Monitor ArgoCD Synchronization
Check the sync status of all microservices and platform components:
```bash
kubectl get applications -n argocd
kubectl get pods -n online-boutique -w
```

### 2. Access the Public Storefront
Retrieve the external AWS Application Load Balancer / Istio Ingress Gateway URL:
```bash
kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```
Open the returned URL in your web browser to view the Online Boutique web storefront.

### 3. Access Monitoring & ArgoCD Dashboards
```bash
# Grafana (Credentials: admin / <GRAFANA_ADMIN_PASSWORD>)
kubectl port-forward svc/grafana 3000:80 -n monitoring

# ArgoCD Web UI (Username: admin; default password retrieved via CLI)
kubectl port-forward svc/argocd-server 8080:443 -n argocd
```

To retrieve the initial ArgoCD admin password:
```bash
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d
```

---

## How CI/CD & GitOps Automation Works

1. **Code Changes & Testing:** Developers commit and push service code to `online-boutique-app` (`main` branch or pull requests).
2. **Automated CI Build & Push:** The [`ci-main.yml`](.github/workflows/ci-main.yml) orchestrator detects modified microservices, builds container images, executes unit tests and lint checks, and pushes tagged images to Amazon ECR.
3. **Automated Manifest Update:** The [`update-manifests`](.github/actions/update-manifests/action.yml) composite action checks out `online-boutique-config` on the branch specified by `CONFIG_REPO_BRANCH` (`deploy/dev`), updates `newTag` for each updated image in `overlays/dev/kustomization.yaml`, and pushes the commit using `CONFIG_REPO_TOKEN`.
4. **GitOps Rollout:** ArgoCD detects changes on `deploy/dev` and automatically performs a rolling update to the Amazon EKS cluster without manual intervention.

---

## Teardown & Resource Cleanup

To completely destroy all cloud resources and avoid ongoing AWS charges, follow the comprehensive destruction sequence in:

📖 **[Teardown & Destruction Guide](devops/destroy-guide.md)**

Resources must be destroyed in strict reverse dependency order:
1. Delete ArgoCD Applications and Kubernetes Ingress Load Balancers.
2. Destroy Dev Environment Infrastructure (`terraform destroy` in `terraform-aws/environments/dev`).
3. Destroy Global ECR Repositories and GitHub OIDC Roles.
4. Destroy Terraform S3 State Backend.

---

## Standard Placeholders Reference

The following table documents every standardized placeholder used throughout this project:

| Placeholder | Description | Usage Context |
|---|---|---|
| `<AWS_ACCOUNT_ID>` | 12-digit AWS Account ID | ECR URLs, IAM ARNs, S3 backend bucket name, GitHub Variables |
| `<AWS_REGION>` | Target AWS deployment region | Terraform configurations, ECR URLs, GitHub Variables |
| `<GITHUB_ORG>` | GitHub username or organization | GitHub OIDC trust policy, repository URLs, clone paths |
| `<IAM_USERNAME>` | AWS IAM username | EKS cluster administrator access in `terraform.tfvars` |
| `<SONAR_ORG>` | SonarCloud organization key | SonarCloud static analysis config (`sonar-project.properties`) |
| `<SONAR_PROJECT_KEY>` | SonarCloud project key | SonarCloud static analysis config (`sonar-project.properties`) |
| `<REDIS_ENDPOINT>` | ElastiCache Redis primary endpoint | Private cache address in `overlays/<env>/env.properties` |
| `<GRAFANA_ADMIN_PASSWORD>` | Password for Grafana `admin` user | Supplied securely at bootstrap; stored in Kubernetes Secret |
