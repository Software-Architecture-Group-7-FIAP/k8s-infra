# Cross-repository contract (ADR-0071): plain String/StringList only; secrets never go to SSM.
resource "aws_ssm_parameter" "string" {
  for_each = var.strings

  name  = "${var.prefix}/${each.key}"
  type  = "String"
  tier  = "Standard"
  value = each.value
  tags  = var.tags
}

resource "aws_ssm_parameter" "list" {
  for_each = var.lists

  name  = "${var.prefix}/${each.key}"
  type  = "StringList"
  tier  = "Standard"
  value = join(",", each.value)
  tags  = var.tags
}
