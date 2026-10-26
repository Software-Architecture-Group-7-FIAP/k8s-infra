module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.name
  cidr = var.cidr
  azs  = var.azs

  public_subnets   = var.public_subnets
  private_subnets  = var.workload_subnets
  database_subnets = var.isolated_subnets
  intra_subnets    = var.alb_subnets

  public_subnet_suffix   = "public"
  private_subnet_suffix  = "workload"
  database_subnet_suffix = "isolated"
  intra_subnet_suffix    = "alb"

  # Cost decision (ADR-0071): one shared NAT for the whole ephemeral session.
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  # Nothing is launched in public subnets except the NAT; never auto-assign public IPs.
  map_public_ip_on_launch = false

  # Isolated route table without default route; the database subnet group is owned by database-infra.
  create_database_subnet_group           = false
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = var.tags
}

# Free gateway endpoint: S3 traffic (image layers, artifacts) skips the NAT data charge.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(module.vpc.private_route_table_ids, module.vpc.database_route_table_ids, module.vpc.intra_route_table_ids)

  tags = merge(var.tags, { Name = "${var.name}-s3" })
}

data "aws_region" "current" {}

# Dedicated Lambda security group (owned here, referenced by database-infra and lambda-auth).
resource "aws_security_group" "lambda" {
  name        = "${var.name}-lambda"
  description = "lambda-auth ENIs: egress to RDS and HTTPS only"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-lambda" })
}

resource "aws_vpc_security_group_egress_rule" "lambda_postgres" {
  security_group_id = aws_security_group.lambda.id
  description       = "PostgreSQL to isolated subnets"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = var.cidr
}

resource "aws_vpc_security_group_egress_rule" "lambda_https" {
  security_group_id = aws_security_group.lambda.id
  description       = "HTTPS to AWS APIs (Secrets Manager, KMS) through the NAT"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
