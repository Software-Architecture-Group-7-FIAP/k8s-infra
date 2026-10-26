output "parameter_names" {
  description = "Every parameter name published by this contract."
  value       = sort(concat([for p in aws_ssm_parameter.string : p.name], [for p in aws_ssm_parameter.list : p.name]))
}
