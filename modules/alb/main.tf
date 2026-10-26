resource "aws_security_group" "alb" {
  name        = "${var.name}-internal-alb"
  description = "Internal ALB reached by API Gateway VPC Link V2"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-internal-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_listener" {
  for_each = var.environments

  security_group_id = aws_security_group.alb.id
  description       = "${each.key} listener from inside the VPC"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "alb_to_pods" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Application port on Pods (node SG)"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = var.node_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb" {
  security_group_id            = var.node_security_group_id
  description                  = "Application port from internal ALB"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_lb" "this" {
  name                       = "${var.name}-int"
  internal                   = true
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.subnet_ids
  drop_invalid_header_fields = true
  idle_timeout               = 60

  # Ephemeral staging: must be destroyable by session-down.
  enable_deletion_protection = false

  tags = var.tags
}

resource "aws_lb_target_group" "env" {
  for_each = var.environments

  name        = "${var.name}-${each.key}"
  port        = var.app_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  deregistration_delay = 15

  health_check {
    path                = "/health/ready"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(var.tags, { Environment = each.key })
}

resource "aws_lb_listener" "env" {
  for_each = var.environments

  load_balancer_arn = aws_lb.this.arn
  port              = each.value
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.env[each.key].arn
  }

  tags = merge(var.tags, { Environment = each.key })
}
