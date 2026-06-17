resource "aws_vpc" "private" {
  count = local.full_private_stack_enabled ? 1 : 0

  cidr_block           = local.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "private" {
  count = local.full_private_stack_enabled ? 1 : 0

  vpc_id = aws_vpc.private[0].id

  tags = { Name = "${local.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  count = local.full_private_stack_enabled ? length(local.public_subnet_cidrs) : 0

  vpc_id                  = local.private_vpc_id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${local.name_prefix}-public-${local.az_suffixes[count.index]}" }
}

resource "aws_route_table" "public" {
  count = local.full_private_stack_enabled ? 1 : 0

  vpc_id = local.private_vpc_id

  tags = { Name = "${local.name_prefix}-public-rt" }
}

resource "aws_route" "public_internet" {
  count = local.full_private_stack_enabled ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.private[0].id
}

resource "aws_route_table_association" "public" {
  count = local.full_private_stack_enabled ? length(local.public_subnet_cidrs) : 0

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_subnet" "private_app" {
  count = local.full_private_stack_enabled ? length(local.private_app_subnet_cidrs) : 0

  vpc_id                  = local.private_vpc_id
  cidr_block              = local.private_app_subnet_cidrs[count.index]
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${local.name_prefix}-private-lambda-${local.az_suffixes[count.index]}" }
}

resource "aws_subnet" "private_db" {
  count = local.full_private_stack_enabled ? length(local.private_db_subnet_cidrs) : 0

  vpc_id                  = local.private_vpc_id
  cidr_block              = local.private_db_subnet_cidrs[count.index]
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${local.name_prefix}-private-rds-${local.az_suffixes[count.index]}" }
}

resource "aws_eip" "nat" {
  count = local.full_private_stack_enabled ? length(local.public_subnet_cidrs) : 0

  domain = "vpc"

  tags = { Name = "${local.name_prefix}-nat-eip-${local.az_suffixes[count.index]}" }
}

resource "aws_nat_gateway" "this" {
  count = local.full_private_stack_enabled ? length(local.public_subnet_cidrs) : 0

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  depends_on = [aws_route.public_internet]

  tags = { Name = "${local.name_prefix}-nat-${local.az_suffixes[count.index]}" }
}

resource "aws_route_table" "private_app" {
  count = local.full_private_stack_enabled ? length(local.private_app_subnet_cidrs) : 0

  vpc_id = local.private_vpc_id

  tags = { Name = "${local.name_prefix}-private-lambda-rt-${local.az_suffixes[count.index]}" }
}

resource "aws_route" "private_app_nat" {
  count = local.full_private_stack_enabled ? length(local.private_app_subnet_cidrs) : 0

  route_table_id         = aws_route_table.private_app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private_app" {
  count = local.full_private_stack_enabled ? length(local.private_app_subnet_cidrs) : 0

  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app[count.index].id
}

resource "aws_route_table" "private_db" {
  count = local.full_private_stack_enabled ? 1 : 0

  vpc_id = local.private_vpc_id

  tags = { Name = "${local.name_prefix}-private-rds-rt" }
}

resource "aws_route_table_association" "private_db" {
  count = local.full_private_stack_enabled ? length(local.private_db_subnet_cidrs) : 0

  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private_db[0].id
}

resource "aws_vpc_endpoint" "s3" {
  count = local.full_private_stack_enabled ? 1 : 0

  vpc_id            = local.private_vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(aws_route_table.private_app[*].id, aws_route_table.private_db[*].id)

  tags = { Name = "${local.name_prefix}-s3-gw-endpoint" }
}

# Interface VPC endpoints (PrivateLink). Move the in-VPC Lambdas' SNS and Secrets
# Manager traffic OFF the NAT onto the AWS backbone. private_dns_enabled=true makes
# the SDK default hostnames (sns/secretsmanager.<region>.amazonaws.com) resolve to
# these endpoint ENIs, so that traffic does NOT fall back to the NAT — the endpoint
# SG (443 from lambda-sg) and Private DNS must both be correct or those calls fail
# silently. The NAT STAYS: it is still required for the users_service Cognito
# Hosted-UI /oauth2/token exchange, which no VPC endpoint can serve. S3 keeps its
# free Gateway endpoint above. Final state: 2 interface endpoints (SNS, Secrets
# Manager) + 1 S3 gateway endpoint + retained NAT (Cognito Hosted-UI).
resource "aws_security_group" "vpce" {
  count = local.full_private_stack_enabled ? 1 : 0

  name        = "${local.name_prefix}-vpce-sg"
  description = "Interface VPC endpoint ENIs: HTTPS from DB-backed Lambdas only."
  vpc_id      = local.private_vpc_id
  ingress     = []
  egress      = []

  tags = { Name = "${local.name_prefix}-vpce-sg" }

  lifecycle {
    ignore_changes = [ingress, egress]
  }
}

resource "aws_security_group_rule" "vpce_from_lambda" {
  count = local.full_private_stack_enabled ? 1 : 0

  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.vpce[0].id
  source_security_group_id = aws_security_group.lambda[0].id
}

resource "aws_security_group_rule" "vpce_egress" {
  count = local.full_private_stack_enabled ? 1 : 0

  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.vpce[0].id
}

resource "aws_vpc_endpoint" "secretsmanager" {
  count = local.full_private_stack_enabled ? 1 : 0

  vpc_id              = local.private_vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_app_subnet_ids
  security_group_ids  = [aws_security_group.vpce[0].id]
  private_dns_enabled = true

  tags = { Name = "${local.name_prefix}-secretsmanager-endpoint" }
}

resource "aws_vpc_endpoint" "sns" {
  count = local.full_private_stack_enabled ? 1 : 0

  vpc_id              = local.private_vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.sns"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_app_subnet_ids
  security_group_ids  = [aws_security_group.vpce[0].id]
  private_dns_enabled = true

  tags = { Name = "${local.name_prefix}-sns-endpoint" }
}

resource "aws_security_group" "lambda" {
  count = local.full_private_stack_enabled ? 1 : 0

  name        = "${local.name_prefix}-lambda-sg"
  description = "DB-backed Lambda egress to RDS Proxy only."
  vpc_id      = local.private_vpc_id
  ingress     = []
  egress      = []

  tags = { Name = "${local.name_prefix}-lambda-sg" }

  lifecycle {
    ignore_changes = [ingress, egress]
  }
}

resource "aws_security_group" "rds_proxy" {
  count = local.full_private_stack_enabled ? 1 : 0

  name        = "${local.name_prefix}-rds-proxy-sg"
  description = "RDS Proxy access from DB-backed Lambdas."
  vpc_id      = local.private_vpc_id
  ingress     = []
  egress      = []

  tags = { Name = "${local.name_prefix}-rds-proxy-sg" }

  lifecycle {
    ignore_changes = [ingress, egress]
  }
}

resource "aws_security_group" "rds" {
  count = local.full_private_stack_enabled ? 1 : 0

  name        = "${local.name_prefix}-rds-sg"
  description = "Private RDS access from RDS Proxy only."
  vpc_id      = local.private_vpc_id
  ingress     = []
  egress      = []

  tags = { Name = "${local.name_prefix}-rds-sg" }

  lifecycle {
    ignore_changes = [ingress, egress]
  }
}

resource "aws_security_group_rule" "lambda_to_rds_proxy" {
  count = local.full_private_stack_enabled ? 1 : 0

  type                     = "egress"
  from_port                = local.postgres_port
  to_port                  = local.postgres_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lambda[0].id
  source_security_group_id = aws_security_group.rds_proxy[0].id
}

resource "aws_security_group_rule" "lambda_https_egress" {
  count = local.full_private_stack_enabled ? 1 : 0

  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.lambda[0].id
}

resource "aws_security_group_rule" "rds_proxy_from_lambda" {
  count = local.full_private_stack_enabled ? 1 : 0

  type                     = "ingress"
  from_port                = local.postgres_port
  to_port                  = local.postgres_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds_proxy[0].id
  source_security_group_id = aws_security_group.lambda[0].id
}

resource "aws_security_group_rule" "rds_proxy_to_rds" {
  count = local.full_private_stack_enabled ? 1 : 0

  type                     = "egress"
  from_port                = local.postgres_port
  to_port                  = local.postgres_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds_proxy[0].id
  source_security_group_id = aws_security_group.rds[0].id
}

resource "aws_security_group_rule" "rds_from_proxy" {
  count = local.full_private_stack_enabled ? 1 : 0

  type                     = "ingress"
  from_port                = local.postgres_port
  to_port                  = local.postgres_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds[0].id
  source_security_group_id = aws_security_group.rds_proxy[0].id
}

resource "aws_db_subnet_group" "private" {
  count = local.full_private_stack_enabled ? 1 : 0

  name       = "${local.name_prefix}-private-db"
  subnet_ids = local.private_db_subnet_ids

  lifecycle {
    ignore_changes = [subnet_ids]
  }
}

resource "aws_db_instance" "postgres" {
  count = local.full_private_stack_enabled ? 1 : 0

  identifier             = "${local.name_prefix}-postgres"
  engine                 = "postgres"
  instance_class         = local.rds_instance_class
  allocated_storage      = local.rds_allocated_storage
  db_name                = var.postgres_db
  username               = var.postgres_user
  password               = var.postgres_password
  port                   = local.postgres_port
  db_subnet_group_name   = aws_db_subnet_group.private[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]
  publicly_accessible    = false
  multi_az               = true
  deletion_protection    = false
  skip_final_snapshot    = true
  storage_encrypted      = true

  tags = { Name = "${local.name_prefix}-postgres" }

  lifecycle {
    precondition {
      condition     = try(length(trimspace(var.postgres_user)) > 0, false)
      error_message = "postgres_user is required when enable_full_private_stack=true."
    }

    precondition {
      condition     = try(length(trimspace(var.postgres_password)) > 0, false)
      error_message = "postgres_password is required when enable_full_private_stack=true."
    }
  }
}

resource "aws_secretsmanager_secret" "db" {
  count = local.full_private_stack_enabled ? 1 : 0

  name                    = "${local.name_prefix}/postgres"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  count = local.full_private_stack_enabled ? 1 : 0

  secret_id = aws_secretsmanager_secret.db[0].id
  secret_string = jsonencode({
    username = var.postgres_user
    password = var.postgres_password
    engine   = "postgres"
    host     = aws_db_instance.postgres[0].address
    port     = local.postgres_port
    dbname   = var.postgres_db
  })
}

resource "aws_db_proxy" "users" {
  count = local.full_private_stack_enabled ? 1 : 0

  name                   = "${local.name_prefix}-rds-proxy"
  engine_family          = "POSTGRESQL"
  idle_client_timeout    = 1800
  require_tls            = local.postgres_tls_enabled
  role_arn               = local.lab_role_arn
  vpc_security_group_ids = [aws_security_group.rds_proxy[0].id]
  vpc_subnet_ids         = local.private_db_subnet_ids

  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = aws_secretsmanager_secret.db[0].arn
  }

  tags = { Name = "${local.name_prefix}-rds-proxy" }
}

resource "aws_db_proxy_default_target_group" "users" {
  count = local.full_private_stack_enabled ? 1 : 0

  db_proxy_name = aws_db_proxy.users[0].name

  connection_pool_config {
    connection_borrow_timeout    = 120
    max_connections_percent      = 90
    max_idle_connections_percent = 50
  }
}

# A Multi-AZ RDS instance can briefly report "available" before its host is
# attached. RegisterDBProxyTargets run in that window fails with
# InvalidDBInstanceState ("instance does not have any host"). This explicit wait
# bridges that gap before proxy target registration.
resource "time_sleep" "wait_for_db_host" {
  depends_on      = [aws_db_instance.postgres]
  create_duration = "120s"
}

resource "aws_db_proxy_target" "users" {
  count = local.full_private_stack_enabled ? 1 : 0

  db_instance_identifier = aws_db_instance.postgres[0].identifier
  db_proxy_name          = aws_db_proxy.users[0].name
  target_group_name      = aws_db_proxy_default_target_group.users[0].name

  depends_on = [aws_secretsmanager_secret_version.db, time_sleep.wait_for_db_host]
}
