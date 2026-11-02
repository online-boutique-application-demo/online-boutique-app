# Setup Guide — Online Boutique DevOps Project

This guide provides end-to-end instructions for configuring, provisioning, and deploying the **Online Boutique** cloud-native microservices platform on **Amazon Web Services (AWS)** using Terraform, GitHub Actions, and ArgoCD (GitOps).

All sensitive and environment-specific values in this repository have been sanitized into standardized placeholders. Following this guide will help you configure both the application repository (`online-boutique-app`) and configuration repository (`online-boutique-config`) for your own AWS account and GitHub organization.

---

## Prerequisites

Before starting, ensure you have the following prerequisites configured:

### Cloud & Code Repositories
- **AWS Account:** Active AWS account with IAM Administrator access (or sufficient privileges for VPC, EKS, ECR, ElastiCache, S3, DynamoDB, and IAM roles).
- **GitHub Account:** Two repositories created under your GitHub user or organization:
  1. `online-boutique-app` (source code, Dockerfiles, Terraform IaC, CI pipelines)
  2. `online-boutique-config` (Kubernetes manifests, Kustomize overlays, ArgoCD Application definitions)

### CLI Tools
Install and verify the following tools on your local machine:
| Tool | Minimum Version | Installation / Verification Command |
|---|---|---|
| **AWS CLI** | `v2.x` | `aws --version` |
| **Terraform** | `>= 1.12.0` | `terraform -version` |
| **kubectl** | `>= 1.36.0` | `kubectl version --client` |
| **Helm** | `>= 3.x` | `helm version` |
| **Git** | `>= 2.x` | `git --version` |
| **Docker** | `>= 20.x` | `docker --version` |

### Optional Tools
- **istioctl** (`>= 1.24`): Useful for debugging Istio service mesh and inspecting mutual TLS (`istioctl proxy-status`).
- **argocd CLI** (`>= 2.10`): Useful for managing ArgoCD applications from the terminal.

---

## Step 1: Clone Repositories

Clone both repositories side by side into the same parent directory. This relative directory structure is required by the setup scripts and deployment workflows:

```bash
mkdir -p online-boutique-workspace
cd online-boutique-workspace

# Replace <YOUR_GITHUB_ORG> with your GitHub organization or username
git clone https://github.com/<YOUR_GITHUB_ORG>/online-boutique-app.git
git clone https://github.com/<YOUR_GITHUB_ORG>/online-boutique-config.git
```

Your directory structure must look like this:
```
online-boutique-workspace/
├── online-boutique-app/
└── online-boutique-config/
```

---

## Step 2: Configure GitHub Repository Variables

Set up GitHub Actions repository variables in **both** repositories (`online-boutique-app` and `online-boutique-config`):

1. Navigate to your repository on GitHub.
2. Go to **Settings** → **Secrets and variables** → **Actions** → **Variables** tab.
3. Click **New repository variable** and add the following:

| Variable | Description | Example |
|---|---|---|
| `AWS_ACCOUNT_ID` | Your 12-digit AWS Account ID | `123456789012` |
| `AWS_REGION` | Target AWS region for infrastructure and ECR | `ap-southeast-1` |
| `IAM_USERNAME` | Your IAM user name (used for EKS cluster admin access) | `admin-devops` |

> **Note:** To find your AWS Account ID, run:
> ```bash
> aws sts get-caller-identity --query "Account" --output text
> ```

---

## Step 3: Configure GitHub Repository Secrets

Configure secrets required for automated CI/CD pipelines:

1. In the `online-boutique-app` repository, go to **Settings** → **Secrets and variables** → **Actions** → **Secrets** tab.
2. Click **New repository secret** and add the following:

| Secret | Description | Required? |
|---|---|---|
| `CONFIG_REPO_TOKEN` | GitHub Personal Access Token (classic) with `repo` scope. Allows GitHub Actions in `online-boutique-app` to push updated image tags to `online-boutique-config`. | **Required** for CI GitOps trigger |
| `SONAR_TOKEN` | SonarCloud project analysis token for static application security testing (SAST). | Optional |

### Generating `CONFIG_REPO_TOKEN`:
1. In GitHub, click your profile picture → **Settings** → **Developer Settings** → **Personal access tokens** → **Tokens (classic)**.
2. Click **Generate new token (classic)**.
3. Name the token (e.g., `online-boutique-gitops-sync`).
4. Select the `repo` scope (Full control of private repositories).
5. Generate and copy the token into GitHub Repository Secrets as `CONFIG_REPO_TOKEN`.

---

## Step 4: Run Setup Script

The automated setup script scans both repositories and replaces all placeholder strings with your actual environment values.

### Execute the Script

#### On Linux / macOS (Bash)
```bash
cd online-boutique-app
chmod +x scripts/setup.sh
./scripts/setup.sh
```

#### On Windows (PowerShell)
```powershell
cd online-boutique-app
.\scripts\setup.ps1
```

### Script Prompts & Inputs
The script will interactively prompt you for the following inputs:
- **AWS Account ID:** Your 12-digit AWS account ID.
- **AWS Region:** AWS deployment region (defaults to `ap-southeast-1`).
- **IAM Username:** Your IAM user name for EKS cluster administration.
- **GitHub Organization/Username:** Your GitHub org or account hosting the repositories.
- **GitHub Username for README attribution:** Defaults to your GitHub Org.
- **Contact Email:** Author/maintainer contact email in README.
- **EKS Cluster Names:**
  - Dev cluster name (defaults to `online-boutique-dev`).
  - Staging cluster name (defaults to `online-boutique-staging`).
- **Redis Endpoint:** Private ElastiCache endpoint (press Enter to skip for later until provisioned).
- **Grafana Admin Password:** Admin password for Grafana UI (defaults to `admin`).
- **SonarCloud Organization & Project Key:** SonarCloud credentials (press Enter to skip if not using SonarCloud).

The script outputs a summary of all modified files across both repositories.

---

## Step 5: Set Up Terraform S3 Backend

Terraform stores its state file remotely in an Amazon S3 bucket with native locking enabled. Set up the backend infrastructure first:

1. Navigate to the S3 backend directory:
   ```bash
   cd terraform-aws/global/s3-backend
   ```

2. Initialize and apply the module using local state to create the remote S3 bucket:
   ```bash
   terraform init
   terraform apply
   ```
   *Note: This creates the S3 bucket `online-boutique-tfstate-<YOUR_AWS_ACCOUNT_ID>` with default AES256 KMS encryption, versioning, and public access blocks.*

3. Enable remote state migration:
   - Copy `backend.tf.example` to `backend.tf`:
     ```bash
     cp backend.tf.example backend.tf
     ```
   - Verify that `<YOUR_AWS_ACCOUNT_ID>` has been replaced with your actual AWS Account ID (the setup script replaces this automatically).
   - Re-initialize Terraform to migrate local state into the S3 bucket:
     ```bash
     terraform init -migrate-state
     ```

---

## Step 6: Deploy Infrastructure

With the S3 state backend operational, provision the global resources and the dev environment:

### 1. Provision Global ECR Repositories
```bash
cd ../ecr
terraform init
terraform apply -auto-approve
```

### 2. Provision GitHub Actions OIDC Role
Create the IAM role that allows GitHub Actions to assume an IAM role securely without long-lived AWS credentials:
```bash
cd ../github-oidc
terraform init
terraform apply -auto-approve
```

### 3. Deploy Dev Environment (VPC, EKS, ElastiCache)
```bash
cd ../../environments/dev

# Copy example variables if terraform.tfvars does not exist
if [ ! -f terraform.tfvars ]; then
  cp terraform.tfvars.example terraform.tfvars
fi

terraform init
terraform plan
terraform apply
```
*Note: EKS cluster provisioning typically takes 12–18 minutes.*

Once Terraform completes, take note of the ElastiCache Redis endpoint in the Terraform output. If you skipped this step during initial setup, update `overlays/dev/patches/cartservice-redis.yaml` in `online-boutique-config` with your Redis endpoint:
```yaml
- op: replace
  path: /spec/template/spec/containers/0/env/0/value
  value: "<YOUR_REDIS_ENDPOINT>:6379"
```

---

## Step 7: Verify & Deploy Applications

### 1. Configure Local kubectl
Connect your local terminal to the newly provisioned Amazon EKS cluster:
```bash
aws eks update-kubeconfig --region ap-southeast-1 --name online-boutique-dev
```

### 2. Verify Node Health
```bash
kubectl get nodes -o wide
```
Ensure all worker nodes report `Ready`.

### 3. Bootstrap GitOps with ArgoCD
Apply the ArgoCD application manifests for the dev environment:
```bash
kubectl apply -f ../../../../online-boutique-config/argocd/apps/dev/
```

### 4. Monitor Application Rollout
Verify that ArgoCD synchronizes all services into the `online-boutique` namespace:
```bash
kubectl get applications -n argocd
kubectl get pods -n online-boutique -w
```

### 5. Access Dashboards & Public Storefront
```bash
# Get external ALB / Istio Gateway URL
kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Access Grafana Dashboard (Credentials: admin / <GRAFANA_ADMIN_PASSWORD>)
kubectl port-forward svc/grafana 3000:80 -n monitoring

# Access ArgoCD Web UI
kubectl port-forward svc/argocd-server 8080:443 -n argocd
```

---

## Placeholders Reference

The following table documents every placeholder used across both repositories, its purpose, and the files in which it appears:

| Placeholder | Description | Used In |
|---|---|---|
| `<AWS_ACCOUNT_ID>` | 12-digit AWS Account ID | CI workflows (`ci-main.yml`, `ci-service.yml`, `terraform-*.yml`), Terraform (`environments/*/terraform.tfvars.example`), Kubernetes manifests (`base/online-boutique/*.yaml`), Kustomize overlays (`overlays/*/kustomization.yaml`), ArgoCD apps (`aws-lb-controller.yaml`, `cluster-autoscaler.yaml`), Kyverno policies (`verify-image-signature.yaml`), and documentation. |
| `<YOUR_AWS_ACCOUNT_ID>` | Same 12-digit AWS Account ID | Terraform S3 backend config (`global/s3-backend/backend.tf.example`), IAM cluster admin ARN examples (`environments/*/terraform.tfvars.example`). |
| `<AWS_REGION>` | AWS region for infrastructure | CI workflows, ArgoCD Helm values (`aws-lb-controller.yaml`, `cluster-autoscaler.yaml`), Kyverno image verification policies, README, and Runbooks. |
| `<YOUR_IAM_USERNAME>` | IAM user name for cluster admin access | Terraform variables (`environments/*/terraform.tfvars.example`). |
| `<GITHUB_ORG>` | GitHub organization or username | ArgoCD application repo URLs (`argocd/apps/*/*.yaml`), Kyverno Cosign subject verification policy, README badges and clone URLs. |
| `<YOUR_GITHUB_ORG>` | Same as `GITHUB_ORG` | Terraform GitHub OIDC trust policy (`global/github-oidc/main.tf`), GitHub Code Owners (`.github/CODEOWNERS`). |
| `<YOUR_GITHUB_USERNAME>` | GitHub username of repository maintainer | README author link and credits (`README.md`). |
| `<YOUR_EMAIL>` | Maintainer contact email | README author contact (`README.md`). |
| `<REDIS_ENDPOINT>` | AWS ElastiCache Redis primary endpoint | Config repo cartservice patch (`overlays/dev/patches/cartservice-redis.yaml`, `overlays/staging/patches/cartservice-redis.yaml`). |
| `<GRAFANA_ADMIN_PASSWORD>` | Administrator password for Grafana UI | ArgoCD Helm values (`argocd/apps/dev/kube-prometheus-stack.yaml`), Prometheus stack values (`base/monitoring/prometheus-stack-values.yaml`). |
| `<EKS_CLUSTER_NAME>` | EKS cluster identifier (e.g., `online-boutique-dev`) | ArgoCD Helm values (`aws-lb-controller.yaml`, `cluster-autoscaler.yaml`), README, and Runbooks. |
| `<YOUR_SONAR_ORG>` | SonarCloud organization key | SonarCloud project configuration (`sonar-project.properties`). |
| `<YOUR_SONAR_PROJECT_KEY>` | SonarCloud project unique key | SonarCloud project configuration (`sonar-project.properties`). |

---

## Troubleshooting & FAQ

- **Setup script reports missing directory:**  
  Make sure `online-boutique-app` and `online-boutique-config` are located in the same parent directory.
- **GitOps image push fails in CI:**  
  Check that the `CONFIG_REPO_TOKEN` secret has write access to `online-boutique-config` and that repository variable `AWS_ACCOUNT_ID` is set correctly.
- **CartService fails to connect to cache:**  
  Verify that `<REDIS_ENDPOINT>` in `overlays/dev/patches/cartservice-redis.yaml` matches the primary endpoint output by Terraform.
- **Idempotency:**  
  The setup script can be safely re-run if you change your configuration or clone fresh repositories.
