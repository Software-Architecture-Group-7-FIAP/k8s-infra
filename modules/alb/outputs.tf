output "alb_arn" {
  description = "Internal ALB ARN (VPC Link V2 target)."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "Internal ALB DNS name."
  value       = aws_lb.this.dns_name
}

output "security_group_id" {
  description = "Internal ALB security group."
  value       = aws_security_group.alb.id
}

output "listener_arns" {
  description = "Listener ARN per environment."
  value       = { for env, l in aws_lb_listener.env : env => l.arn }
}

output "target_group_arns" {
  description = "IP target group ARN per environment (bound by TargetGroupBinding)."
  value       = { for env, tg in aws_lb_target_group.env : env => tg.arn }
}
