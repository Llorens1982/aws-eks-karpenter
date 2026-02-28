# =============================================================================
# terraform.tfvars - DEV Environment
# Copia este archivo como terraform.tfvars.local para valores sensibles
# =============================================================================

aws_region   = "eu-west-1"
environment  = "dev"
project_name = "myproject"
team         = "platform"

cluster_name    = "myproject-dev"
cluster_version = "1.30"

vpc_cidr              = "10.0.0.0/16"
public_subnets_cidrs  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
private_subnets_cidrs = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]

# En dev: endpoint público restringido a IP de la oficina
endpoint_public_access = true
public_access_cidrs    = ["203.0.113.0/24"]  # Cambiar por tu IP/CIDR

karpenter_version = "1.0.6"

# Roles del equipo con acceso al cluster
additional_iam_roles = [
  {
    arn      = "arn:aws:iam::123456789012:role/DevOpsTeam"
    username = "devops-team"
    groups   = ["system:masters"]
  },
  {
    arn      = "arn:aws:iam::123456789012:role/ReadOnly"
    username = "readonly"
    groups   = ["view"]
  }
]
