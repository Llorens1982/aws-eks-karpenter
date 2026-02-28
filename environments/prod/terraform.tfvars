aws_region   = "eu-west-1"
environment  = "prod"
project_name = "myproject"
team         = "platform"

cluster_name    = "myproject-prod"
cluster_version = "1.30"

vpc_cidr              = "10.1.0.0/16"
public_subnets_cidrs  = ["10.1.1.0/24", "10.1.2.0/24", "10.1.3.0/24"]
private_subnets_cidrs = ["10.1.11.0/24", "10.1.12.0/24", "10.1.13.0/24"]

# PROD: Endpoint completamente privado
endpoint_public_access = false
public_access_cidrs    = []

karpenter_version = "1.0.6"

additional_iam_roles = [
  {
    arn      = "arn:aws:iam::123456789012:role/PlatformTeam"
    username = "platform-team"
    groups   = ["system:masters"]
  }
]
