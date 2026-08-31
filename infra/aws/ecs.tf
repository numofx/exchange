resource "aws_ecs_cluster" "main" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "tasks" {
  for_each          = toset(["markets-service", "matcher", "execution-service", "migrate"])
  name              = "/ecs/${var.name}/${each.key}"
  retention_in_days = 30
}

# ------------------------------------------------------------------------- IAM

data "aws_iam_policy_document" "task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Only the execution role reads secrets, and only these three. The task role below
# gets nothing — none of these containers call AWS APIs at runtime.
data "aws_iam_policy_document" "read_secrets" {
  statement {
    actions   = local.use_ssm ? ["ssm:GetParameters"] : ["secretsmanager:GetSecretValue"]
    resources = values(local.secret_arns)
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.use_ssm ? "ssm.${var.region}.amazonaws.com" : "secretsmanager.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-task-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.read_secrets.json
}

resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
}

# ------------------------------------------------------------- task definitions

locals {
  chain_env = [
    { name = "CHAIN_ID", value = var.chain_id },
    { name = "MATCHING_ADDRESS", value = var.matching_address },
    { name = "TRADE_MODULE_ADDRESS", value = var.trade_module_address },
  ]

  log_options = { for k, g in aws_cloudwatch_log_group.tasks : k => {
    logDriver = "awslogs"
    options = {
      "awslogs-group"         = g.name
      "awslogs-region"        = var.region
      "awslogs-stream-prefix" = "ecs"
    }
  } }
}

# SERVICE_MODE is baked into each definition rather than defaulted at runtime. Paired
# with the boot guard, a definition that loses it fails to start instead of quietly
# booting a second API server with no matcher behind it.

resource "aws_ecs_task_definition" "markets" {
  family                   = "${var.name}-markets-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name         = "markets-service"
    image        = var.image_markets
    essential    = true
    portMappings = [{ containerPort = 8080, protocol = "tcp" }]

    environment = concat(local.chain_env, [
      { name = "SERVICE_MODE", value = "api" },
      { name = "API_ADDR", value = ":8080" },
      { name = "CNGN_SPOT_ASSET_ADDRESS", value = var.cngn_spot_asset_address },
    ])

    secrets = [
      { name = "DATABASE_URL", valueFrom = local.secret_arns.database_url },
      { name = "CHAIN_RPC_URL", valueFrom = local.secret_arns.rpc_url },
    ]

    healthCheck = {
      command     = ["CMD", "/app/api", "-healthcheck"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 20
    }

    logConfiguration = local.log_options["markets-service"]
  }])
}

resource "aws_ecs_task_definition" "matcher" {
  family                   = "${var.name}-matcher"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name       = "matcher"
    image      = var.image_markets # same image, a different binary
    essential  = true
    entryPoint = ["/app/matcher"]

    environment = concat(local.chain_env, [
      { name = "SERVICE_MODE", value = "matcher" },
      { name = "CNGN_SPOT_ASSET_ADDRESS", value = var.cngn_spot_asset_address },
      { name = "MATCHER_POLL_INTERVAL", value = var.matcher_poll_interval },
      # Hostname preserved from Railway — see internal_namespace.
      { name = "EXECUTOR_URL", value = "http://execution-service.${var.internal_namespace}:8081/execute" },
    ])

    secrets = [
      { name = "DATABASE_URL", valueFrom = local.secret_arns.database_url },
      { name = "CHAIN_RPC_URL", valueFrom = local.secret_arns.rpc_url },
    ]

    logConfiguration = local.log_options["matcher"]
  }])
}

resource "aws_ecs_task_definition" "execution" {
  family                   = "${var.name}-execution-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name         = "execution-service"
    image        = var.image_execution
    essential    = true
    portMappings = [{ containerPort = 8081, protocol = "tcp" }]

    environment = concat(local.chain_env, [
      { name = "PORT", value = "8081" },
      { name = "HOST", value = "0.0.0.0" },
      # Both were unset on Railway and defaulted. Stated explicitly here so the
      # value is a decision rather than a default nobody chose.
      { name = "WAIT_FOR_RECEIPT", value = "true" },
      { name = "DRY_RUN", value = "false" },
    ])

    secrets = [
      { name = "PRIVATE_KEY", valueFrom = local.secret_arns.executor_key },
      { name = "RPC_URL", valueFrom = local.secret_arns.rpc_url },
    ]

    healthCheck = {
      command     = ["CMD", "node", "dist/index.js", "--healthcheck"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 20
    }

    logConfiguration = local.log_options["execution-service"]
  }])
}

# Run once, by hand, before the data load: aws ecs run-task --task-definition <this>
resource "aws_ecs_task_definition" "migrate" {
  family                   = "${var.name}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name        = "migrate"
    image       = var.image_markets
    essential   = true
    entryPoint  = ["/app/migrate"]
    environment = [{ name = "SERVICE_MODE", value = "migrate" }]
    secrets     = [{ name = "DATABASE_URL", valueFrom = local.secret_arns.database_url }]

    logConfiguration = local.log_options["migrate"]
  }])
}

# ------------------------------------------------------------------- services

resource "aws_ecs_service" "markets" {
  name            = "markets-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.markets.arn
  desired_count   = var.desired_count_markets
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = aws_subnet.app[*].id
    security_groups = [aws_security_group.app.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.markets.arn
    container_name   = "markets-service"
    container_port   = 8080
  }

  service_registries {
    registry_arn = aws_service_discovery_service.markets.arn
  }

  depends_on = [aws_lb_listener.https]
}

# Exactly one. The matcher reserves rows with FOR UPDATE SKIP LOCKED, so a second
# replica would not corrupt the book — but it would double the RPC load and make
# "which process stranded this pair" ambiguous during the very window this cutover
# is trying to keep legible.
resource "aws_ecs_service" "matcher" {
  name            = "matcher"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.matcher.arn
  desired_count   = var.desired_count_matcher
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets         = aws_subnet.app[*].id
    security_groups = [aws_security_group.app.id]
  }
}

resource "aws_ecs_service" "execution" {
  name            = "execution-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.execution.arn
  desired_count   = var.desired_count_execution
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = aws_subnet.app[*].id
    security_groups = [aws_security_group.app.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.execution.arn
  }
}
