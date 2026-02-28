variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  type = string
}

variable "node_role_arn" {
  type = string
}

variable "node_role_name" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "karpenter_version" {
  description = "Versión del chart de Karpenter"
  type        = string
  default     = "1.0.6"
}

variable "node_pool_cpu_limit" {
  description = "Límite total de CPU para los NodePools"
  type        = string
  default     = "1000"
}

variable "node_pool_memory_limit" {
  description = "Límite total de memoria para los NodePools"
  type        = string
  default     = "4000Gi"
}

variable "tags" {
  type    = map(string)
  default = {}
}
