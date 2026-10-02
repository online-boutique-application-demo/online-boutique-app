# 📐 Git Convention – Online Boutique DevOps Project

> **Ngày tạo:** 2026-10-02  
> **Áp dụng cho:** `online-boutique-app` và `online-boutique-config`

---

## 1. Branching Strategy

### 1.1 Tổng Quan

```
main (stable, production-ready code)
 │
 ├── feature/devops-init              ← Documentation ban đầu
 ├── feature/stage-1-terraform        ← Terraform infrastructure
 ├── feature/stage-2-ci-pipeline      ← GitHub Actions CI
 ├── feature/stage-3-cd-argocd        ← ArgoCD + GitOps
 ├── feature/stage-4-service-mesh     ← Istio + Kiali
 ├── feature/stage-5-monitoring       ← Monitoring & Observability
 └── feature/stage-6-devsecops        ← Security scanning
```

### 1.2 Quy Tắc

| Quy tắc | Mô tả |
|---------|--------|
| **Branch chính** | `main` – luôn ở trạng thái stable |
| **Feature branch** | `feature/<tên-stage>` – tạo từ `main` |
| **Merge strategy** | Merge commit (không squash) – giữ full history |
| **Delete sau merge** | Xóa feature branch sau khi merge vào `main` |

### 1.3 Workflow

```bash
# 1. Tạo feature branch từ main
git checkout main
git pull origin main
git checkout -b feature/stage-1-terraform

# 2. Làm việc, commit theo Conventional Commits
git add .
git commit -m "feat(terraform): add VPC module with 3-tier subnets"

# 3. Push feature branch lên GitHub
git push origin feature/stage-1-terraform

# 4. Tạo Pull Request trên GitHub
#    - Title: "feat(terraform): Stage 1 - AWS Infrastructure"
#    - Description: mô tả chi tiết những gì đã làm
#    - Merge strategy: Create a merge commit (giữ full history)

# 5. Sau khi merge PR trên GitHub, cập nhật local
git checkout main
git pull origin main

# 6. Xóa feature branch local
git branch -d feature/stage-1-terraform
```

---

## 2. Commit Convention (Conventional Commits)

### 2.1 Format

```
<type>(<scope>): <subject>

[optional body]

[optional footer]
```

### 2.2 Types

| Type | Ý nghĩa | Ví dụ |
|------|---------|-------|
| `feat` | Thêm tính năng/resource mới | `feat(terraform): add EKS module with Spot instances` |
| `fix` | Sửa lỗi | `fix(ci): correct ECR login step for ap-southeast-1` |
| `docs` | Thêm/sửa documentation | `docs(devops): add Stage 1 completion report` |
| `chore` | Maintenance, không ảnh hưởng logic | `chore: update .gitignore for terraform files` |
| `ci` | Thay đổi CI/CD pipeline | `ci: add reusable workflow for service builds` |
| `refactor` | Refactor code không thay đổi behavior | `refactor(terraform): extract security groups to module` |
| `style` | Formatting, không thay đổi logic | `style(terraform): run terraform fmt` |
| `test` | Thêm/sửa tests | `test(ci): add workflow validation test` |

### 2.3 Scopes

| Scope | Áp dụng khi |
|-------|------------|
| `terraform` | Thay đổi trong `infra/` |
| `ci` | Thay đổi trong `.github/workflows/` |
| `argocd` | Thay đổi ArgoCD configs |
| `istio` | Thay đổi Istio/Kiali configs |
| `monitoring` | Thay đổi Prometheus/Grafana/Loki/Tempo |
| `security` | Thay đổi security scanning configs |
| `devops` | Thay đổi trong `devops/` documentation |
| `helm` | Thay đổi Helm charts/values |
| `kustomize` | Thay đổi Kustomize overlays |

### 2.4 Ví Dụ Commit Messages

```bash
# Stage 1 - Terraform
feat(terraform): add VPC module with 3-tier subnets and NAT gateway
feat(terraform): add EKS module with Spot node groups and IRSA
feat(terraform): add ECR module with lifecycle policies
feat(terraform): add ElastiCache Redis module for CartService
feat(terraform): add dev environment configuration
feat(terraform): add staging environment configuration
feat(terraform): add IRSA module for AWS LB Controller
docs(devops): add Stage 1 Terraform completion report

# Stage 2 - CI
ci: add reusable workflow for per-service CI builds
ci: add path-based change detection for monorepo
ci: add terraform plan/apply workflows
ci: add Docker build and ECR push composite action
docs(devops): add Stage 2 CI pipeline completion report

# Stage 3 - CD
feat(argocd): add ArgoCD installation Helm values
feat(argocd): add App of Apps pattern for dev environment
feat(kustomize): add base manifests and dev overlay
feat(argocd): add staging environment with manual sync
docs(devops): add Stage 3 CD ArgoCD completion report

# Stage 4 - Istio
feat(istio): add IstioOperator with default profile
feat(istio): add Gateway and VirtualService for frontend
feat(istio): add strict mTLS PeerAuthentication
feat(istio): add service-to-service AuthorizationPolicies
feat(istio): add Kiali dashboard with Prometheus integration
docs(devops): add Stage 4 Service Mesh completion report

# Stage 5 - Monitoring
feat(monitoring): add kube-prometheus-stack Helm values
feat(monitoring): add Loki and Promtail for centralized logging
feat(monitoring): add Tempo for distributed tracing
feat(monitoring): add custom Grafana dashboards for Online Boutique
feat(monitoring): add alert rules for SLA monitoring
docs(devops): add Stage 5 Monitoring completion report

# Stage 6 - Security
ci(security): add Trivy SCA filesystem scanning
ci(security): add SonarQube SAST integration with Quality Gates
ci(security): add Trivy image scanning and Cosign signing
ci(security): add OWASP ZAP DAST scanning for staging
feat(security): add Kyverno policies for pod security
docs(devops): add Stage 6 DevSecOps completion report
```

### 2.5 Quy Tắc Bổ Sung

- **Ngôn ngữ:** Tiếng Anh
- **Subject:** Viết thường, không dấu chấm cuối, tối đa 72 ký tự
- **Body:** Giải thích WHY (tại sao), không phải WHAT (cái gì) – vì WHAT đã rõ trong code
- **Mỗi commit = 1 thay đổi logic** – không gộp nhiều thay đổi không liên quan

---

## 3. Lưu Ý Đặc Biệt

### 3.1 Không Commit Secrets

Các file KHÔNG được commit:
- `*.tfstate` / `*.tfstate.backup`
- `.env`
- `*-credentials.json`
- `*.pem` / `*.key`

→ Đã được xử lý bằng `.gitignore`
