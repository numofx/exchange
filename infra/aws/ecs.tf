resource "aws_ecs_cluster" "main" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "tasks" {
  for_each          = toset(["markets-service", "matcher", "execution-service", "migrate", "market-maker"])
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

# SERVICE_MODE is baked into each definition rather than defaulted at runtime. Nothing
# reads it yet: the binary that runs is chosen by the entryPoint override alone, so
# today this is documentation. It becomes load-bearing when the boot guard lands and
# can assert that the declared mode and the entrypoint agree, which is what would stop
# a mislabelled definition from quietly booting a second API server with no matcher
# behind it.

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
      # WAIT_FOR_RECEIPT must stay false until the matcher can survive the wait.
      # With it on, execution blocks in waitForTransactionReceipt (viem default:
      # 180s, confirmations 1) while the matcher's executor client gives up after
      # 5s (matching/executor.go:79). The timeout is not TM_FillLimitCrossed, so
      # shouldFinalizeAfterExecutorError is false and the pair is released and
      # retried 2s later (matching/backoff.go). That retry simulates against a
      # state where filled[owner][nonce] has not moved yet, because the first tx
      # is still pending -- so it passes, and a second verifyAndMatch goes out on
      # the next nonce for a fill already in flight.
      #
      # Turning this on requires, in order: an executor-client timeout longer
      # than the receipt wait, and an actual check of receipt.status (today a
      # reverted receipt still returns accepted: true, and the Go response struct
      # drops receipt_status entirely).
      { name = "WAIT_FOR_RECEIPT", value = "false" },
      # DRY_RUN was unset on Railway and defaulted. Stated explicitly here so the
      # value is a decision rather than a default nobody chose.
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

# The market maker is the fifth service and the reason the DNS flip is not the whole
# cutover: MM_API_BASE_URL pointed at Railway's own hostname, never api.numofx.com,
# so nothing about a CNAME change would have moved it. It also holds a direct
# database connection, and RDS is publicly_accessible = false in an isolated subnet
# tier — which is what settles the question of migrating it rather than repointing it.
resource "aws_ecs_task_definition" "market_maker" {
  family                   = "${var.name}-market-maker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "market-maker"
    image     = var.image_market_maker
    essential = true

    environment = [
      # Contract addresses are set explicitly so the bot never falls back to
      # resolving them from sibling repo checkouts, which do not exist in the image.
      { name = "MM_CHAIN_ID", value = var.chain_id },
      { name = "MM_MATCHING_ADDRESS", value = var.matching_address },
      { name = "MM_TRADE_MODULE_ADDRESS", value = var.trade_module_address },
      { name = "MM_SUBACCOUNTS_ADDRESS", value = var.subaccounts_address },

      # Cloud Map, not the ALB: this call never needs to leave the app tier.
      { name = "MM_API_BASE_URL", value = "http://markets-service.${var.internal_namespace}:8080" },

      # Arrives paused, exactly as it runs on Railway today. Unpausing is the last
      # step of the cutover and a deliberate one, never a side effect of deploying.
      { name = "MM_OPERATOR_MODE", value = "pause" },
      { name = "MM_DRY_RUN", value = "false" },

      { name = "MM_MARKET_SYMBOL", value = "USDCcNGN-SPOT" },
      { name = "MM_OWNER_ADDRESS", value = var.mm_address },
      { name = "MM_SIGNER_ADDRESS", value = var.mm_address },
      { name = "MM_SUBACCOUNT_ID", value = "10" },
      { name = "MM_RECIPIENT_ID", value = "10" },

      { name = "MM_QUOTE_LEVELS", value = "5" },
      { name = "MM_ORDER_SIZE", value = "1.2" },
      { name = "MM_HALF_SPREAD_BPS", value = "10" },
      { name = "MM_LEVEL_SPREAD_STEP_BPS", value = "15" },
      { name = "MM_LEVEL_SIZE_MULT", value = "1.2" },
      { name = "MM_MAX_NET_INVENTORY", value = "60" },
      { name = "MM_MAX_NOTIONAL_PER_SIDE", value = "15000" },
      { name = "MM_MAX_ANCHOR_DEVIATION_BPS", value = "150" },
      { name = "MM_PROTECTED_ORDER_ID_PREFIXES", value = "validation:,smoke:,manual:,test:" },

      { name = "MM_ANCHOR_SOURCE_TYPE", value = "none" },
      { name = "MM_USDCCNGN_SPOT_EXTERNAL_ANCHOR_ENABLED", value = "true" },
      { name = "MM_USDCCNGN_SPOT_EXTERNAL_ANCHOR_PROVIDER", value = "cngn-price-oracle" },
      { name = "MM_USDCCNGN_SPOT_EXTERNAL_ANCHOR_CHAIN_ID", value = "8453" },
      { name = "MM_USDCCNGN_SPOT_EXTERNAL_ANCHOR_BOOTSTRAP_ONLY", value = "true" },
      { name = "MM_USDCCNGN_SPOT_EXTERNAL_ANCHOR_MAX_AGE_SECONDS", value = "8000" },
      { name = "MM_USDCCNGN_SPOT_EXTERNAL_ANCHOR_MAX_DEVIATION_BPS", value = "100" },
      { name = "MM_USDCCNGN_SPOT_EXTERNAL_ANCHOR_TIMEOUT_MS", value = "1200" },
      { name = "MM_STALE_ANCHOR_TIMEOUT_SECONDS", value = "14400" },

      { name = "MM_METRICS_ADDR", value = ":8080" },
      { name = "MM_READINESS_MISSING_QUOTE_TIMEOUT_SECONDS", value = "120" },
      { name = "MM_SOAK_LOG_INTERVAL_SECONDS", value = "60" },
      { name = "MM_LOG_LEVEL", value = "INFO" },

      # /tmp is writable and ephemeral on Fargate. The bot rebuilds this from the
      # book on startup, so it costs a cycle to lose, not correctness — no volume.
      { name = "MM_STATE_FILE", value = "/tmp/.mm-bot-state.json" },
    ]

    # Owner and signer are the same key today; both names are set so that staying
    # true remains a choice rather than an assumption baked into the definition.
    secrets = [
      { name = "MM_OWNER_PRIVATE_KEY", valueFrom = local.secret_arns.mm_private_key },
      { name = "MM_SIGNER_PRIVATE_KEY", valueFrom = local.secret_arns.mm_private_key },
      { name = "MM_RPC_URL", valueFrom = local.secret_arns.mm_rpc_url },
      { name = "MM_USDCCNGN_SPOT_EXTERNAL_ANCHOR_RPC_URL", valueFrom = local.secret_arns.mm_rpc_url },
      { name = "MM_DATABASE_URL", valueFrom = local.secret_arns.database_url },
    ]

    healthCheck = {
      command     = ["CMD", "/app/mm-bot", "-healthcheck"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 20
    }

    logConfiguration = local.log_options["market-maker"]
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

# No load balancer and no Cloud Map registration: nothing calls into the market
# maker. It only makes outbound calls, to the API, to RDS, and to Base.
resource "aws_ecs_service" "market_maker" {
  name            = "market-maker-spot"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.market_maker.arn
  desired_count   = var.desired_count_market_maker
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }
}
