output "parameter_names" {
  description = "Every parameter name published by this contract."
  value       = sort(concat([for p in aws_ssm_parameter.string : p.name], [for p in aws_ssm_parameter.list : p.name]))
}

output "parameter_contract" {
  description = "Plain contract names, types, and values for post-apply publication verification."
  value = merge(
    {
      for parameter in aws_ssm_parameter.string : parameter.name => {
        type  = parameter.type
        value = parameter.value
      }
    },
    {
      for parameter in aws_ssm_parameter.list : parameter.name => {
        type  = parameter.type
        value = parameter.value
      }
    },
  )
  sensitive = true
}
