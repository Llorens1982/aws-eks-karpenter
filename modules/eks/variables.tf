variable "cluster_name" {
  description = "Nombre del cluster EKS"
  type        = string
}

variable "cluster_version" {
  description = "Versión de Kubernetes"
  type        = string
  default     = "1.30"
}

variable "vpc_id" {
  description = "ID de la VPC"
  type        = string
}

variable "private_subnet_ids" {
  description = "IDs de las subnets privadas para los nodos"
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Habilitar acceso público al API server (false en prod)"
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDRs permitidos si endpoint_public_access = true"
  type        = list(string)
  default     = []
}

variable "service_cidr" {
  description = "CIDR para los services de Kubernetes"
  type        = string
  default     = "172.20.0.0/16"
}

variable "log_retention_days" {
  description = "Días de retención de logs en CloudWatch"
  type        = number
  default     = 30
}

# Node Group Sistema
variable "system_node_instance_types" {
  description = "Tipos de instancia para el node group de sistema"
  type        = list(string)
  default     = ["m5.large", "m5a.large", "m5d.large"]
}

variable "system_node_group_capacity_type" {
  description = "ON_DEMAND o SPOT para el node group de sistema"
  type        = string
  default     = "ON_DEMAND"
}

variable "system_node_group_desired" {
  type    = number
  default = 2
}

variable "system_node_group_min" {
  type    = number
  default = 2
}

variable "system_node_group_max" {
  type    = number
  default = 4
}

# Addon versions - Actualizar según la versión de K8s
variable "addon_coredns_version" {
  type    = string
  default = "v1.11.1-eksbuild.9"
}

variable "addon_kube_proxy_version" {
  type    = string
  default = "v1.30.0-eksbuild.3"
}

variable "addon_vpc_cni_version" {
  type    = string
  default = "v1.18.3-eksbuild.2"
}

variable "addon_ebs_csi_version" {
  type    = string
  default = "v1.33.0-eksbuild.1"
}

variable "addon_efs_csi_version" {
  type    = string
  default = "v2.0.7-eksbuild.1"
}

variable "tags" {
  description = "Tags comunes"
  type        = map(string)
  default     = {}
}
