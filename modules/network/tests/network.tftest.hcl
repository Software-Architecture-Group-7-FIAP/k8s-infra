mock_provider "aws" {
  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }
}

variables {
  name             = "auto-shop-staging"
  cidr             = "10.80.0.0/20"
  azs              = ["us-east-1a", "us-east-1b"]
  public_subnets   = ["10.80.0.0/27", "10.80.0.32/27"]
  workload_subnets = ["10.80.2.0/23", "10.80.4.0/23"]
  isolated_subnets = ["10.80.6.0/24", "10.80.7.0/24"]
  alb_subnets      = ["10.80.8.0/27", "10.80.8.32/27"]
  cluster_name     = "auto-shop-staging"
}

run "single_nat_and_two_azs" {
  command = apply

  assert {
    condition     = output.nat_gateway_count == 1
    error_message = "Exactly one NAT gateway is allowed (ADR-0071 cost decision)."
  }

  assert {
    condition     = length(output.workload_subnet_ids) == 2 && length(output.isolated_subnet_ids) == 2
    error_message = "Workload and isolated subnets must exist in both AZs."
  }
}

run "no_public_ip_auto_assignment" {
  command = apply

  assert {
    condition     = alltrue([for s in module.vpc.public_subnet_objects : s.map_public_ip_on_launch == false])
    error_message = "Public subnets must not auto-assign public IPs."
  }
}

run "isolated_subnets_have_no_default_route" {
  command = apply

  assert {
    condition     = length(module.vpc.database_nat_gateway_route_ids) == 0 && module.vpc.database_internet_gateway_route_id == null
    error_message = "Isolated (RDS) subnets must not have a default route."
  }
}

run "workload_subnets_tagged_for_internal_alb" {
  command = apply

  assert {
    condition     = alltrue([for s in module.vpc.private_subnet_objects : s.tags["kubernetes.io/role/internal-elb"] == "1"])
    error_message = "Workload subnets need the internal-elb discovery tag."
  }
}

run "lambda_sg_allows_only_postgres_in_vpc_and_https" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_egress_rule.lambda_postgres.from_port == 5432 && aws_vpc_security_group_egress_rule.lambda_postgres.cidr_ipv4 == "10.80.0.0/20"
    error_message = "Lambda PostgreSQL egress must be limited to the VPC CIDR."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.lambda_https.from_port == 443
    error_message = "Lambda HTTPS egress must be port 443."
  }
}

run "alb_subnets_are_dedicated_and_isolated" {
  command = apply

  assert {
    condition     = length(output.alb_subnet_ids) == 2
    error_message = "ALB subnets must exist in both AZs."
  }

  assert {
    condition     = alltrue([for cidr in output.alb_subnet_cidrs : !contains(var.workload_subnets, cidr)])
    error_message = "ALB subnets must be distinct from workload subnets so the NetworkPolicy ipBlock can exclude pod traffic."
  }
}

run "rejects_three_azs" {
  command = plan

  variables {
    azs = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }

  expect_failures = [var.azs]
}
