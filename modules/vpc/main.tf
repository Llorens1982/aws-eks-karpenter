# =============================================================================
# MODULE: VPC
# Descripción: VPC production-ready con subnets privadas/públicas,
#              NAT Gateways, VPC Endpoints para tráfico privado a AWS APIs
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# -----------------------------------------------------------------------------
# DATA SOURCES
# -----------------------------------------------------------------------------
data "aws_availability_zones" "available" {
  state = "available"
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-vpc"
    # Tags requeridos por Karpenter y AWS Load Balancer Controller
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# -----------------------------------------------------------------------------
# INTERNET GATEWAY
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = merge(var.tags, { Name = "${var.cluster_name}-igw" })
}

# -----------------------------------------------------------------------------
# SUBNETS PÚBLICAS (ALB, NAT Gateways)
# -----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = length(var.public_subnets_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnets_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-public-${data.aws_availability_zones.available.names[count.index]}"
    # Tag requerido por AWS Load Balancer Controller para descubrir subnets públicas
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# -----------------------------------------------------------------------------
# SUBNETS PRIVADAS (EKS nodes, Karpenter nodes)
# -----------------------------------------------------------------------------
resource "aws_subnet" "private" {
  count = length(var.private_subnets_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnets_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-private-${data.aws_availability_zones.available.names[count.index]}"
    # Tag requerido por AWS Load Balancer Controller para descubrir subnets privadas
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    # Tag requerido por Karpenter para descubrir subnets donde lanzar nodos
    "karpenter.sh/discovery" = var.cluster_name
  })
}

# -----------------------------------------------------------------------------
# ELASTIC IPs para NAT Gateways
# -----------------------------------------------------------------------------
resource "aws_eip" "nat" {
  count  = var.single_nat_gateway ? 1 : length(var.public_subnets_cidrs)
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-eip-nat-${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# NAT GATEWAYS
# High availability: 1 por AZ en producción, 1 único en dev para ahorro de coste
# -----------------------------------------------------------------------------
resource "aws_nat_gateway" "main" {
  count = var.single_nat_gateway ? 1 : length(var.public_subnets_cidrs)

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-nat-${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# ROUTE TABLES - PÚBLICAS
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-rt-public" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# ROUTE TABLES - PRIVADAS
# Cada subnet privada tiene su propia RT para rutar al NAT GW de su AZ
# -----------------------------------------------------------------------------
resource "aws_route_table" "private" {
  count  = var.single_nat_gateway ? 1 : length(var.private_subnets_cidrs)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-rt-private-${count.index + 1}"
  })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = var.single_nat_gateway ? aws_route_table.private[0].id : aws_route_table.private[count.index].id
}

# -----------------------------------------------------------------------------
# VPC ENDPOINTS - Tráfico privado a AWS APIs (sin salir a internet)
# Crítico para EKS con private endpoints y para reducir costes de NAT GW
# -----------------------------------------------------------------------------

# Security Group para VPC Endpoints
resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${var.cluster_name}-vpce-"
  description = "Security group for VPC Endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-vpce-sg" })
}

locals {
  # Endpoints de tipo Interface (PrivateLink)
  interface_endpoints = {
    "ecr_api"    = "com.amazonaws.${var.aws_region}.ecr.api"
    "ecr_dkr"    = "com.amazonaws.${var.aws_region}.ecr.dkr"
    "sts"        = "com.amazonaws.${var.aws_region}.sts"
    "ec2"        = "com.amazonaws.${var.aws_region}.ec2"
    "logs"       = "com.amazonaws.${var.aws_region}.logs"
    "ssm"        = "com.amazonaws.${var.aws_region}.ssm"
    "ssmmessages" = "com.amazonaws.${var.aws_region}.ssmmessages"
    "elasticloadbalancing" = "com.amazonaws.${var.aws_region}.elasticloadbalancing"
    "autoscaling" = "com.amazonaws.${var.aws_region}.autoscaling"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.main.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.cluster_name}-vpce-${each.key}" })
}

# Endpoint de tipo Gateway (S3 y DynamoDB - gratuitos)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(var.tags, { Name = "${var.cluster_name}-vpce-s3" })
}
