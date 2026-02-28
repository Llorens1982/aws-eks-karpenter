variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "project_name" {
  type    = string
  default = "myproject"
}

variable "team" {
  type    = string
  default = "platform"
}

variable "cluster_name" {
  type    = string
}

variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnets_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnets_cidrs" {
  type    = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "endpoint_public_access" {
  type    = bool
  default = true  # true en dev para acceso directo, false en prod
}

variable "public_access_cidrs" {
  description = "CIDRs con acceso al API server público"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # Restringir en prod a IPs de la oficina/VPN
}

variable "karpenter_version" {
  type    = string
  default = "1.0.6"
}

variable "additional_iam_roles" {
  description = "Roles IAM adicionales con acceso al cluster"
  type = list(object({
    arn      = string
    username = string
    groups   = list(string)
  }))
  default = []
}

variable "additional_iam_users" {
  description = "Usuarios IAM con acceso al cluster"
  type = list(object({
    arn      = string
    username = string
    groups   = list(string)
  }))
  default = []
}
