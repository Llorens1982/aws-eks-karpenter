output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = true
}

output "configure_kubectl_command" {
  description = "Comando para configurar kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "karpenter_role_arn" {
  value = module.karpenter.karpenter_controller_role_arn
}
