output "karpenter_controller_role_arn" {
  value = aws_iam_role.karpenter_controller.arn
}

output "karpenter_node_instance_profile_name" {
  value = aws_iam_instance_profile.karpenter_node.name
}

output "interruption_queue_name" {
  value = aws_sqs_queue.karpenter_interruption.name
}

output "interruption_queue_arn" {
  value = aws_sqs_queue.karpenter_interruption.arn
}
