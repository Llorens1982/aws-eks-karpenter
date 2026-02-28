# =============================================================================
# MODULE: KARPENTER
# Descripción: Despliega Karpenter como autoscaler de nodos en EKS.
#              Karpenter observa pods pending y provisiona nodos EC2 directamente
#              sin pasar por ASG, siendo mucho más rápido que Cluster Autoscaler.
#
# Flujo: Pod Pending → Karpenter detecta → Crea EC2 → Node Ready → Pod corre
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# SQS QUEUE - Interruption Handler
# Karpenter escucha eventos de spot interruption, rebalance y health events
# para drenar nodos antes de que AWS los termine
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = merge(var.tags, { Name = "${var.cluster_name}-karpenter-interruption" })
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.karpenter_interruption.arn
      }
    ]
  })
}

# EventBridge Rules para capturar eventos de interrupción
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.cluster_name}-spot-interruption"
  description = "Captura avisos de interrupción Spot (2 min antes)"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "rebalance" {
  name        = "${var.cluster_name}-rebalance"
  description = "Captura recomendaciones de rebalance EC2"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
}

resource "aws_cloudwatch_event_target" "rebalance" {
  rule = aws_cloudwatch_event_rule.rebalance.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "instance_state_change" {
  name        = "${var.cluster_name}-instance-state"
  description = "Captura cambios de estado de instancias EC2"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
}

resource "aws_cloudwatch_event_target" "instance_state_change" {
  rule = aws_cloudwatch_event_rule.instance_state_change.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

# -----------------------------------------------------------------------------
# IAM ROLE - Karpenter Controller (IRSA)
# Este role permite a Karpenter lanzar/terminar instancias EC2
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "karpenter_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_controller" {
  name               = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.karpenter_assume_role.json
  tags               = var.tags
}

# Política IAM para el controller de Karpenter
resource "aws_iam_policy" "karpenter_controller" {
  name        = "${var.cluster_name}-karpenter-controller"
  description = "Política para Karpenter Controller - gestión de nodos EC2"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Crear y gestionar instancias EC2
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:RunInstances",
          "ec2:CreateTags",
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeInstances",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeSpotPriceHistory",
        ]
        Resource = "*"
      },
      # Pasar el role de nodo a las instancias EC2
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = var.node_role_arn
      },
      # Obtener parámetros de SSM (AMIs optimizadas para EKS)
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:*:*:parameter/aws/service/eks/optimized-ami/*"
      },
      # Escuchar la cola SQS de interrupciones
      {
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage",
        ]
        Resource = aws_sqs_queue.karpenter_interruption.arn
      },
      # Obtener info del cluster EKS
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
      },
      # Pricing API para optimización de costes
      {
        Effect   = "Allow"
        Action   = ["pricing:GetProducts"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

# -----------------------------------------------------------------------------
# INSTANCE PROFILE para los nodos que Karpenter lanzará
# Los nodos EC2 lanzados por Karpenter necesitan este instance profile
# para unirse al cluster EKS
# -----------------------------------------------------------------------------
resource "aws_iam_instance_profile" "karpenter_node" {
  name = "KarpenterNodeInstanceProfile-${var.cluster_name}"
  role = var.node_role_name
  tags = var.tags
}

# -----------------------------------------------------------------------------
# HELM RELEASE - Karpenter Controller
# -----------------------------------------------------------------------------
resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "karpenter"
  create_namespace = true
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version
  wait             = true
  timeout          = 300

  values = [
    yamlencode({
      settings = {
        clusterName       = var.cluster_name
        clusterEndpoint   = var.cluster_endpoint
        interruptionQueue = aws_sqs_queue.karpenter_interruption.name
      }

      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.karpenter_controller.arn
        }
      }

      controller = {
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { memory = "1Gi" }
        }
      }

      # Karpenter controller corre en los nodos de sistema
      tolerations = [{
        key      = "CriticalAddonsOnly"
        operator = "Exists"
        effect   = "NoSchedule"
      }]

      nodeSelector = {
        role = "system"
      }

      # Alta disponibilidad
      replicas = 2

      podDisruptionBudget = {
        minAvailable = 1
      }
    })
  ]

  depends_on = [aws_iam_role_policy_attachment.karpenter_controller]
}

# -----------------------------------------------------------------------------
# EC2NODE CLASS - Define las propiedades de los nodos EC2 que lanzará Karpenter
# (AMI, subnets, security groups, instance profile)
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "ec2_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      # AMI optimizada para EKS - se actualiza automáticamente
      amiFamily = "AL2023"

      # Karpenter descubre subnets y SGs por tags
      subnetSelectorTerms = [{
        tags = {
          "karpenter.sh/discovery" = var.cluster_name
        }
      }]

      securityGroupSelectorTerms = [{
        tags = {
          "karpenter.sh/discovery" = var.cluster_name
        }
      }]

      instanceProfile = aws_iam_instance_profile.karpenter_node.name

      # Configuración del volumen raíz
      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs = {
          volumeSize = "50Gi"
          volumeType = "gp3"
          iops       = 3000
          throughput = 125
          encrypted  = true
          kmsKeyID   = var.kms_key_arn
        }
      }]

      # IMDSv2 obligatorio en todos los nodos
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpProtocolIPv6        = "disabled"
        httpPutResponseHopLimit = 1
        httpTokens              = "required"
      }

      # userData adicional para configurar los nodos
      userData = <<-EOT
        #!/bin/bash
        # Configuraciones adicionales del nodo
        echo "vm.max_map_count=262144" >> /etc/sysctl.conf
        sysctl -p
      EOT

      tags = merge(var.tags, {
        "karpenter.sh/discovery" = var.cluster_name
      })
    }
  })

  depends_on = [helm_release.karpenter]
}

# -----------------------------------------------------------------------------
# NODE POOL - General Purpose (Spot + On-Demand con fallback)
# Karpenter intentará Spot primero, fallback a On-Demand
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "node_pool_general" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "general"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            role = "general"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }

          # Tipos de instancia permitidos - variedad máxima para Spot
          requirements = [
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["spot", "on-demand"]  # Spot primero
            },
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["c", "m", "r"]  # Compute, Memory, General
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["2"]  # Solo generaciones recientes
            },
            {
              key      = "karpenter.k8s.aws/instance-size"
              operator = "NotIn"
              values   = ["nano", "micro", "small"]  # Excluir instancias pequeñas
            },
          ]

          # Tiempo máximo que un nodo puede vivir (rotación forzada)
          expireAfter = "720h"  # 30 días

          # Tiempo de gracia para terminar nodo vacío
          terminationGracePeriod = "48h"
        }
      }

      # Límites del NodePool (coste controlado)
      limits = {
        cpu    = var.node_pool_cpu_limit
        memory = var.node_pool_memory_limit
      }

      # Política de consolidación de nodos (ahorro de costes)
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
        budgets = [{
          nodes = "10%"  # Max 10% de nodos en disruption simultáneamente
        }]
      }
    }
  })

  depends_on = [kubectl_manifest.ec2_node_class]
}

# -----------------------------------------------------------------------------
# NODE POOL - ARM64 (Graviton) para cargas de trabajo compatibles
# ~20% más barato que x86 equivalente
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "node_pool_arm64" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "arm64"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            role = "arm64"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }

          requirements = [
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["arm64"]  # Solo Graviton
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["spot", "on-demand"]
            },
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["m", "c", "r"]
            },
          ]

          expireAfter = "720h"
        }
      }

      limits = {
        cpu    = "100"
        memory = "400Gi"
      }

      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }
    }
  })

  depends_on = [kubectl_manifest.ec2_node_class]
}
