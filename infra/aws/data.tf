# ------------------------------------------------------------------------- RDS

resource "aws_db_subnet_group" "main" {
  name       = "${var.name}-db"
  subnet_ids = aws_subnet.db[*].id
  tags       = { Name = "${var.name}-db" }
}

resource "aws_db_parameter_group" "pg18" {
  name   = "${var.name}-pg18"
  family = "postgres18"

  # Production runs Etc/UTC. A restored copy on any other timezone renders
  # timestamptz differently — the stored values are identical, but every log line,
  # API response and CSV export shifts by the offset.
  parameter {
    name  = "timezone"
    value = "UTC"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "random_password" "db" {
  length  = 40
  special = false # keeps the value safe to paste into a URL without escaping
}

resource "aws_db_instance" "main" {
  identifier     = "${var.name}-pg"
  engine         = "postgres"
  engine_version = "18.4" # exact match with the Railway source; no cross-version restore
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "markets"
  username = "numo"
  password = random_password.db.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.pg18.name
  publicly_accessible    = false

  multi_az                = var.db_multi_az
  backup_retention_period = 7
  copy_tags_to_snapshot   = true

  # The Railway volume filled up once already. Alarm on this well before it matters.
  performance_insights_enabled = true
  auto_minor_version_upgrade   = false # pin the minor: a silent bump breaks dump parity

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-pg-final"

  tags = { Name = "${var.name}-pg" }
}

# --------------------------------------------------------- private service DNS

# The namespace is railway.internal so EXECUTOR_URL and DATABASE_URL survive the
# move unchanged. Cloud Map manages the ECS service records; the RDS endpoint gets
# a plain CNAME in the same zone.
resource "aws_service_discovery_private_dns_namespace" "internal" {
  name        = var.internal_namespace
  vpc         = aws_vpc.main.id
  description = "Mirrors Railway private networking so service URLs carry over verbatim"
}

resource "aws_service_discovery_service" "markets" {
  name = "markets-service"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.internal.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_service_discovery_service" "execution" {
  name = "execution-service"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.internal.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

# postgres.railway.internal -> RDS, so DATABASE_URL keeps the hostname it had.
resource "aws_route53_record" "postgres_internal" {
  zone_id = aws_service_discovery_private_dns_namespace.internal.hosted_zone
  name    = "postgres.${var.internal_namespace}"
  type    = "CNAME"
  ttl     = 60
  records = [aws_db_instance.main.address]
}
