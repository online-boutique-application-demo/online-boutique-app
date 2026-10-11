# =============================================================================
# EKS Add-ons
# Essential cluster add-ons managed by AWS
#
# Ordering matters:
#   - vpc-cni and kube-proxy are created BEFORE the node group so that nodes
#     join the cluster with prefix delegation already enabled (max pods is
#     calculated when the node is launched).
#   - coredns and aws-ebs-csi-driver run as Deployments and need nodes, so
#     they are created AFTER the node group.
# =============================================================================

locals {
  addon_names = ["vpc-cni", "kube-proxy", "coredns", "aws-ebs-csi-driver"]
}

# Pin each add-on to the latest version compatible with the cluster version,
# so upgrades are explicit and visible in `terraform plan`.
data "aws_eks_addon_version" "this" {
  for_each = toset(local.addon_names)

  addon_name         = each.value
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

# -----------------------------------------------------------------------------
# Networking add-ons (before compute)
# -----------------------------------------------------------------------------
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  addon_version               = data.aws_eks_addon_version.this["vpc-cni"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Prefix delegation assigns /28 prefixes instead of single IPs to ENIs,
  # raising the pod limit per node (e.g. t3.large: 35 -> 110 pods).
  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = tostring(var.enable_prefix_delegation)
      WARM_PREFIX_TARGET       = "1"
    }
  })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  addon_version               = data.aws_eks_addon_version.this["kube-proxy"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# -----------------------------------------------------------------------------
# Workload add-ons (after compute)
# -----------------------------------------------------------------------------
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  addon_version               = data.aws_eks_addon_version.this["coredns"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = data.aws_eks_addon_version.this["aws-ebs-csi-driver"].version
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

# -----------------------------------------------------------------------------
# EBS CSI Driver IRSA Role
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Condition = {
          StringEquals = {
            "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
            "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi.name
}
