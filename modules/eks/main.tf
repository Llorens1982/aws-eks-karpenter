# =============================================================================
# MODULE: EKS
# Descripción: Cluster EKS con private endpoints, managed node groups para
#              sistema, addons gestionados y OIDC provider para IRSA
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# -----------------------------------------------------------------------------
# KMS KEY para encriptar secrets de Kubernetes en etcd
# -----------------------------------------------------------------------------
resource "aws_kms_key" "eks" {
  description             = "KMS key para encriptar secrets del cluster ${var.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(var.tags, { Name = "${var.cluster_name}-kms" })
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}"
  target_key_id = aws_kms_key.eks.key_id
}

# -----------------------------------------------------------------------------
# IAM ROLE - EKS Control Plane
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "eks_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController",
  ])
  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# -----------------------------------------------------------------------------
# SECURITY GROUP - EKS Control Plane
# -----------------------------------------------------------------------------
resource "aws_security_group" "cluster" {
  name_prefix = "${var.cluster_name}-cluster-"
  description = "Security group del EKS Control Plane"
  vpc_id      = var.vpc_id

  # Egress libre - el control plane necesita comunicarse con los nodos
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-cluster-sg" })
}

# -----------------------------------------------------------------------------
# EKS CLUSTER
# -----------------------------------------------------------------------------
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true  # Acceso privado habilitado
    endpoint_public_access  = var.endpoint_public_access  # false en prod
    public_access_cidrs     = var.public_access_cidrs
  }

  # Encriptación de secrets con KMS
  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  # Logs del control plane a CloudWatch
  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  # Configuración de redes
  kubernetes_network_config {
    service_ipv4_cidr = var.service_cidr
    ip_family         = "ipv4"
  }

  tags = merge(var.tags, {
    Name = var.cluster_name
    # Tag requerido por Karpenter
    "karpenter.sh/discovery" = var.cluster_name
  })

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policies,
    aws_cloudwatch_log_group.eks,
  ]
}

# CloudWatch Log Group para control plane logs
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# -----------------------------------------------------------------------------
# OIDC PROVIDER - Requerido para IRSA (IAM Roles for Service Accounts)
# Permite a los pods de K8s asumir roles IAM sin credenciales estáticas
# -----------------------------------------------------------------------------
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  tags            = merge(var.tags, { Name = "${var.cluster_name}-oidc" })
}

# -----------------------------------------------------------------------------
# IAM ROLE - Node Groups (EC2 nodes)
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",  # Para SSM Session Manager
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# -----------------------------------------------------------------------------
# MANAGED NODE GROUP - Sistema (CoreDNS, Karpenter controller, etc.)
# Estos nodos NO escalan con Karpenter, son el "floor" del cluster
# -----------------------------------------------------------------------------
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  # Instance types con Spot para ahorro (con fallback)
  capacity_type  = var.system_node_group_capacity_type
  instance_types = var.system_node_instance_types

  scaling_config {
    desired_size = var.system_node_group_desired
    min_size     = var.system_node_group_min
    max_size     = var.system_node_group_max
  }

  update_config {
    max_unavailable_percentage = 33
  }

  # Taint para que solo los pods de sistema se scheduleén aquí
  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  labels = {
    role = "system"
    "karpenter.sh/controller" = "true"
  }

  # Volumen raíz con encriptación
  launch_template {
    id      = aws_launch_template.system_nodes.id
    version = aws_launch_template.system_nodes.latest_version
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-system-ng" })

  depends_on = [aws_iam_role_policy_attachment.node_policies]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

resource "aws_launch_template" "system_nodes" {
  name_prefix   = "${var.cluster_name}-system-lt-"
  instance_type = var.system_node_instance_types[0]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.eks.arn
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv2 obligatorio
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, { Name = "${var.cluster_name}-system-node" })
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# EKS ADDONS - Gestionados por AWS (auto-updates)
# -----------------------------------------------------------------------------
locals {
  addons = {
    coredns = {
      version               = var.addon_coredns_version
      resolve_conflicts     = "OVERWRITE"
      configuration_values  = jsonencode({
        replicaCount = 2
        resources = {
          limits   = { cpu = "200m", memory = "256Mi" }
          requests = { cpu = "100m", memory = "128Mi" }
        }
        tolerations = [{
          key      = "CriticalAddonsOnly"
          operator = "Exists"
          effect   = "NoSchedule"
        }]
      })
    }
    kube-proxy = {
      version              = var.addon_kube_proxy_version
      resolve_conflicts    = "OVERWRITE"
      configuration_values = null
    }
    vpc-cni = {
      version              = var.addon_vpc_cni_version
      resolve_conflicts    = "OVERWRITE"
      # Habilitar prefix delegation para más pods por nodo
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    aws-ebs-csi-driver = {
      version              = var.addon_ebs_csi_version
      resolve_conflicts    = "OVERWRITE"
      service_account_role_arn = aws_iam_role.ebs_csi.arn
      configuration_values     = null
    }
    aws-efs-csi-driver = {
      version              = var.addon_efs_csi_version
      resolve_conflicts    = "OVERWRITE"
      service_account_role_arn = aws_iam_role.efs_csi.arn
      configuration_values     = null
    }
  }
}

resource "aws_eks_addon" "addons" {
  for_each = local.addons

  cluster_name             = aws_eks_cluster.main.name
  addon_name               = each.key
  addon_version            = each.value.version
  resolve_conflicts_on_update = each.value.resolve_conflicts
  service_account_role_arn = lookup(each.value, "service_account_role_arn", null)
  configuration_values     = each.value.configuration_values

  tags = merge(var.tags, { Name = "${var.cluster_name}-addon-${each.key}" })

  depends_on = [aws_eks_node_group.system]
}

# -----------------------------------------------------------------------------
# IRSA - EBS CSI Driver
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# IRSA - EFS CSI Driver
data "aws_iam_policy_document" "efs_csi_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:efs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role" "efs_csi" {
  name               = "${var.cluster_name}-efs-csi-role"
  assume_role_policy = data.aws_iam_policy_document.efs_csi_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  role       = aws_iam_role.efs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}
