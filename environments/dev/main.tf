# =============================================================================
# ENVIRONMENT: DEV
# Orquesta todos los módulos para desplegar el stack completo EKS + Karpenter
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Backend S3 - Cambia por tu bucket y tabla DynamoDB
  backend "s3" {
    bucket         = "my-terraform-state-bucket"
    key            = "eks-karpenter/dev/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}

# -----------------------------------------------------------------------------
# PROVIDERS
# -----------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# El provider de Helm y kubectl necesitan las credenciales del cluster
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region", var.aws_region
      ]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.aws_region
    ]
  }
}

# -----------------------------------------------------------------------------
# LOCALS
# -----------------------------------------------------------------------------
locals {
  common_tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "Terraform"
    Repository  = "eks-karpenter-terraform"
    Owner       = var.team
  }
}

# -----------------------------------------------------------------------------
# MODULE: VPC
# -----------------------------------------------------------------------------
module "vpc" {
  source = "../../modules/vpc"

  cluster_name          = var.cluster_name
  vpc_cidr              = var.vpc_cidr
  public_subnets_cidrs  = var.public_subnets_cidrs
  private_subnets_cidrs = var.private_subnets_cidrs
  single_nat_gateway    = true  # En dev usamos 1 NAT GW para ahorrar costes
  aws_region            = var.aws_region
  tags                  = local.common_tags
}

# -----------------------------------------------------------------------------
# MODULE: EKS
# -----------------------------------------------------------------------------
module "eks" {
  source = "../../modules/eks"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  vpc_id          = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  # En dev el endpoint puede ser público para facilitar el desarrollo
  endpoint_public_access = var.endpoint_public_access
  public_access_cidrs    = var.public_access_cidrs

  # Node group sistema - más pequeño en dev
  system_node_instance_types      = ["t3.medium", "t3a.medium"]
  system_node_group_capacity_type = "ON_DEMAND"
  system_node_group_desired       = 2
  system_node_group_min           = 2
  system_node_group_max           = 4

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# MODULE: KARPENTER
# -----------------------------------------------------------------------------
module "karpenter" {
  source = "../../modules/karpenter"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  node_role_arn     = module.eks.node_role_arn
  node_role_name    = module.eks.node_role_name
  kms_key_arn       = module.eks.kms_key_arn

  karpenter_version      = var.karpenter_version
  node_pool_cpu_limit    = "200"   # Límites menores en dev
  node_pool_memory_limit = "800Gi"

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# AWS AUTH - Dar acceso al cluster a los usuarios/roles del equipo
# Karpenter también necesita su role en el configmap
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "aws_auth" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "aws-auth"
      namespace = "kube-system"
    }
    data = {
      mapRoles = yamlencode(concat(
        # Role de los nodos (obligatorio)
        [{
          rolearn  = module.eks.node_role_arn
          username = "system:node:{{EC2PrivateDNSName}}"
          groups   = ["system:bootstrappers", "system:nodes"]
        }],
        # Role de Karpenter para los nodos que lanza
        [{
          rolearn  = module.karpenter.karpenter_controller_role_arn
          username = "system:node:{{EC2PrivateDNSName}}"
          groups   = ["system:bootstrappers", "system:nodes"]
        }],
        # Roles adicionales del equipo
        [for role in var.additional_iam_roles : {
          rolearn  = role.arn
          username = role.username
          groups   = role.groups
        }]
      ))
      mapUsers = yamlencode([
        for user in var.additional_iam_users : {
          userarn  = user.arn
          username = user.username
          groups   = user.groups
        }
      ])
    }
  })

  depends_on = [module.eks]
}

# -----------------------------------------------------------------------------
# STORAGE CLASSES - gp3 como default
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "storage_class_gp3" {
  yaml_body = yamlencode({
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name = "gp3"
      annotations = {
        "storageclass.kubernetes.io/is-default-class" = "true"
      }
    }
    provisioner          = "ebs.csi.aws.com"
    volumeBindingMode    = "WaitForFirstConsumer"
    allowVolumeExpansion = true
    parameters = {
      type      = "gp3"
      iops      = "3000"
      throughput = "125"
      encrypted = "true"
    }
  })

  depends_on = [module.eks]
}

# Parchar el storage class gp2 para que no sea default
resource "kubectl_manifest" "storage_class_gp2_patch" {
  yaml_body = yamlencode({
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name = "gp2"
      annotations = {
        "storageclass.kubernetes.io/is-default-class" = "false"
      }
    }
    provisioner = "kubernetes.io/aws-ebs"
  })

  depends_on = [module.eks]
}
