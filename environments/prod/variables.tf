variable "aws_region"     { type = string }
variable "environment"    { type = string }
variable "project_name"   { type = string }
variable "team"           { type = string }
variable "cluster_name"   { type = string }
variable "cluster_version" { type = string; default = "1.30" }
variable "vpc_cidr"       { type = string }
variable "public_subnets_cidrs"  { type = list(string) }
variable "private_subnets_cidrs" { type = list(string) }
variable "endpoint_public_access" { type = bool; default = false }
variable "public_access_cidrs"   { type = list(string); default = [] }
variable "karpenter_version"     { type = string; default = "1.0.6" }
variable "additional_iam_roles" {
  type = list(object({ arn = string; username = string; groups = list(string) }))
  default = []
}
variable "additional_iam_users" {
  type = list(object({ arn = string; username = string; groups = list(string) }))
  default = []
}
