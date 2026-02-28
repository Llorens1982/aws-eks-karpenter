# =============================================================================
# ENVIRONMENT: PROD
# Igual que dev pero con configuración hardened para producción
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    helm   = { source = "hashicorp/helm", version = "~> 2.12" }
    kubectl = { source = "gavinbunney/kubectl", version = "~> 1.14" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
  }

  backend "s3" {
    bucket         = "my-terraform-state-bucket-prod"
    key            = "eks-karpenter/prod/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
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
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

locals {
  common_tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "Terraform"
    Repository  = "eks-karpenter-terraform"
    Owner       = var.team
  }
}

module "vpc" {
  source = "../../modules/vpc"

  cluster_name          = var.cluster_name
  vpc_cidr              = var.vpc_cidr
  public_subnets_cidrs  = var.public_subnets_cidrs
  private_subnets_cidrs = var.private_subnets_cidrs
  single_nat_gateway    = false  # PROD: 1 NAT GW por AZ para HA
  aws_region            = var.aws_region
  tags                  = local.common_tags
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = var.cluster_name
  cluster_version    = var.cluster_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  # PROD: Solo acceso privado
  endpoint_public_access = false
  public_access_cidrs    = []

  # Nodos de sistema más potentes en prod
  system_node_instance_types      = ["m5.xlarge", "m5a.xlarge"]
  system_node_group_capacity_type = "ON_DEMAND"
  system_node_group_desired       = 3
  system_node_group_min           = 3
  system_node_group_max           = 6

  log_retention_days = 90  # Mayor retención en prod

  tags = local.common_tags
}

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
  node_pool_cpu_limit    = "2000"
  node_pool_memory_limit = "8000Gi"

  tags = local.common_tags
}
