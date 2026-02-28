variable "cluster_name" {
  description = "Nombre del cluster EKS (usado en tags de Kubernetes)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block para la VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets_cidrs" {
  description = "CIDRs para subnets públicas (una por AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnets_cidrs" {
  description = "CIDRs para subnets privadas (una por AZ) - aquí irán los nodos EKS"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "single_nat_gateway" {
  description = "Usar un solo NAT GW (ahorra coste en dev, NO recomendado en prod)"
  type        = bool
  default     = false
}

variable "aws_region" {
  description = "Región AWS donde se despliega la VPC"
  type        = string
}

variable "tags" {
  description = "Tags comunes aplicados a todos los recursos"
  type        = map(string)
  default     = {}
}
