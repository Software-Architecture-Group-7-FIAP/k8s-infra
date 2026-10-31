mock_provider "aws" {
  mock_resource "aws_lb" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:035611741563:loadbalancer/app/auto-shop-staging-int/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:035611741563:targetgroup/auto-shop-staging/0123456789abcdef"
    }
  }
}

variables {
  name                   = "auto-shop-staging"
  vpc_id                 = "vpc-0123456789abcdef0"
  subnet_ids             = ["subnet-aaaa", "subnet-bbbb"]
  node_security_group_id = "sg-0nodes"
  app_port               = 8000
  environments = {
    hml = 8001
    prd = 8002
  }
}

run "alb_is_internal" {
  command = apply

  assert {
    condition     = aws_lb.this.internal == true && aws_lb.this.load_balancer_type == "application"
    error_message = "The ALB must be internal; API Gateway is the only public entry point."
  }

  assert {
    condition     = aws_lb.this.drop_invalid_header_fields == true
    error_message = "ALB must drop invalid header fields."
  }
}

run "one_listener_and_ip_target_group_per_environment" {
  command = apply

  assert {
    condition     = length(aws_lb_listener.env) == 2 && aws_lb_listener.env["hml"].port == 8001 && aws_lb_listener.env["prd"].port == 8002
    error_message = "Listeners 8001 (hml) and 8002 (prd) are the Gateway contract."
  }

  assert {
    condition     = alltrue([for tg in aws_lb_target_group.env : tg.target_type == "ip" && tg.port == 8000])
    error_message = "Target groups must use IP targets on the application port (TargetGroupBinding)."
  }

  assert {
    condition     = alltrue([for tg in aws_lb_target_group.env : tg.health_check[0].path == "/health/ready"])
    error_message = "Health check must exercise readiness (database included)."
  }
}

run "alb_ingress_is_owned_by_vpc_link_stack_and_nodes_only_accept_alb" {
  command = apply

  assert {
    condition     = length(aws_security_group.alb.ingress) == 0
    error_message = "The ALB module must not add CIDR ingress; the application stack owns VPC Link SG ingress."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.nodes_from_alb.from_port == 8000 && aws_vpc_security_group_ingress_rule.nodes_from_alb.referenced_security_group_id == aws_security_group.alb.id
    error_message = "Pods (node SG) must accept the app port only from the ALB SG."
  }
}

run "rejects_reused_listener_port" {
  command = plan

  variables {
    environments = {
      hml = 8001
      prd = 8001
    }
  }

  expect_failures = [var.environments]
}
