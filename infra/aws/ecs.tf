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
  # TRADE_MODULE_ADDRESS and QUOTE_ASSET_ADDRESS are a pair: the second is the first's
  # quoteAsset(). They must move together, in one apply, or the funding check reads a ledger
  # the trade does not touch. See variables.tf for the two valid combinations.
  chain_env = [
    { name = "CHAIN_ID", value = var.chain_id },
    { name = "MATCHING_ADDRESS", value = var.matching_address },
    { name = "TRADE_MODULE_ADDRESS", value = var.trade_module_address },
    { name = "QUOTE_ASSET_ADDRESS", value = var.quote_asset_address },
    { name = "CASH_ASSET_ADDRESS", value = var.cash_asset_address },
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

      # Every one of these was set on Railway and every one has a code default that
      # differs from it or is empty. Omitting them silently relaxed the service:
      # ENFORCE_ORDER_SIGNATURES and ENFORCE_CANCEL_SIGNATURES default to false, so
      # an order with an unverifiable signature would rest on the book as depth that
      # can never settle, and a cancel would be honoured without proving ownership.
      # They are stated here rather than left to defaults so a missing variable can
      # never quietly weaken enforcement again.
      { name = "ENFORCE_ORDER_SIGNATURES", value = "true" },
      { name = "ENFORCE_CANCEL_SIGNATURES", value = "true" },
      { name = "ENFORCE_MATCHING_CUSTODY", value = "true" },
      { name = "ENFORCE_ACTION_DATA_INVARIANTS", value = "true" },
      { name = "CANCEL_PROTECTED_ORDER_ID_PREFIXES", value = var.cancel_protected_order_id_prefixes },

      # Empty means same-origin only, which rejects the browser app's websocket and
      # takes the live order book down without any error the API would surface.
      { name = "WS_ALLOWED_ORIGINS", value = var.ws_allowed_origins },
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
      # Must exceed execution-service's RECEIPT_TIMEOUT_MS (60s). See that setting.
      { name = "EXECUTOR_TIMEOUT", value = "90s" },
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
      # The receipt wait is bounded here rather than left at viem's 180s default,
      # because EXECUTOR_TIMEOUT on the matcher (90s, below) must outlast it. If the
      # matcher gave up first, the transaction would still be in flight, the pair
      # would be released, and the retry would simulate against a nonce whose fill
      # had not landed -- passing, and broadcasting a second verifyAndMatch for a
      # fill already on the wire. 60s < 90s keeps that window closed.
      { name = "RECEIPT_TIMEOUT_MS", value = "60000" },
      # Still false. The two hazards that made it dangerous are closed: a reverted
      # receipt now comes back as accepted: false rather than a recorded fill, and a
      # receipt-wait timeout comes back as an UNKNOWN outcome, on which the matcher
      # declines to release the pair rather than retrying a transaction that may
      # still mine.
      #
      # The remaining cost of turning it on is operational, not correctness: an
      # unknown outcome strands both orders in `matching` until someone resolves
      # them against the chain, and there is no tooling for that yet. No tx_hash is
      # persisted on the fill row either, so the resolution is manual.
      { name = "WAIT_FOR_RECEIPT", value = "false" },
      # DRY_RUN was unset on Railway and defaulted. Stated explicitly here so the
      # value is a decision rather than a default nobody chose.
      { name = "DRY_RUN", value = "false" },

      # Settlement canary. Calls StandardManager.getMargin against a real subaccount on a
      # timer and reports the result in /healthz. It exists because the 2026-09-01 feed
      # outage was silent for 6.8 days: services healthy, orders matching, every on-chain
      # settlement reverting.
      #
      # The account id matters. An empty subaccount has no market holding, so the manager
      # reads no spot feed and the check passes while proving nothing. 15 is the SRM
      # account holding wrapped cNGN (market 2) and is the only funded one today, so this
      # leg exercises market 2 only. Deposit a little wrapped USDC into it to cover market
      # 1 as well. Until then market 1 is still covered by the ops-side canary, which reads
      # every market's feed directly rather than inferring it from what someone holds.
      { name = "SETTLEMENT_CANARY_MANAGER", value = "0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b" },
      { name = "SETTLEMENT_CANARY_ACCOUNTS", value = "15" },
      { name = "SETTLEMENT_CANARY_INTERVAL_MS", value = "60000" },
      # Re-alert after 30 consecutive failing checks (30 minutes at a 60s interval), so one
      # dropped webhook is not silence for the whole outage.
      { name = "SETTLEMENT_CANARY_ALERT_REPEAT_CHECKS", value = "30" },

      # netSettledCash pinned to its live value rather than required to be zero. CashAsset's
      # _getTotalCash SUBTRACTS netSettledCash, so settled cash is excluded from what must be
      # backed -- and donateBalance burns against that same quantity, so a max donate from the
      # account owner burns exactly 0 (verified on a Base fork). Requiring zero would page
      # forever about a value no available call can change. A MOVEMENT means a manager printed
      # or burned settled cash, which is the event worth waking someone for.
      #
      # This makes the canary prove "not insolvent by CashAsset's own accounting", NOT 1:1
      # backing. The wrapper invariant is the one that proves 1:1, and it covers only the
      # wrapped assets.
      { name = "SETTLEMENT_CANARY_EXPECTED_NET_SETTLED_CASH", value = "13682574719999999999990057939082285597678" },

      # The wrapped-quote fee path, live from the 2026-09-10 cutover. Subaccount 17 is
      # vault-owned and deliberately NOT in Matching custody: setAssetAllowances keys the grant
      # by ownerOf(accountId), so a custodied account would key it to the Matching contract and
      # the vault could not grant one at all.
      # STANDING EXCEPTION, 2026-09-10. The wrapped-USDC contract permanently holds 5.000000
      # USDC more than it has credited, from tx 0xfcf33112414f44cc53c493e28da4ec57cde8d029ac
      # 3920144aceab23dbe5656b (block 51125714): a plain ERC20 transfer sent through MPCVault's
      # "Send USDC" flow during the cutover, where the intended deposit(15, 5000000) had nowhere
      # to put its calldata. Unrecoverable -- WrappedERC20Asset exposes only deposit and
      # withdraw, both strictly 1:1, has no rescue path, and is not behind a proxy.
      #
      # PINNED, not tolerated: healthy at exactly +5e18, red the moment it moves either way.
      # Widening this to "over-backed is fine" would discard the property that caught the
      # transfer within minutes of it happening.
      { name = "SETTLEMENT_CANARY_WRAPPER_EXCEPTIONS", value = "0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84:5000000000000000000" },

      { name = "SETTLEMENT_CANARY_FEE_SUBACCOUNT", value = "17" },
      { name = "SETTLEMENT_CANARY_FEE_OWNER", value = "0x1dcA42ab54Bd3862853A821F84B29BF65245F435" },
      { name = "SETTLEMENT_CANARY_FEE_MODULE", value = "0x12423B366F6F07130961900bE00d05Ea63Acd071" },
      { name = "SETTLEMENT_CANARY_FEE_QUOTE_ASSET", value = "0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84" },
      # Reporting, not liveness. Restarting this container does not refresh a stale oracle,
      # and failing the health check would pull the API out of the target group and flap
      # tasks while the real fault sits off-box. The canary's job is to make the halt
      # visible; the alerting on it is numo-settlement-canary.timer on the ops box.
      { name = "SETTLEMENT_CANARY_FAILS_HEALTHCHECK", value = "false" },
    ])

    secrets = [
      { name = "PRIVATE_KEY", valueFrom = local.secret_arns.executor_key },
      { name = "RPC_URL", valueFrom = local.secret_arns.rpc_url },
      # The canary's only route to a person. There is no CloudWatch alarm on this log group, so
      # without this a failing canary writes a line nobody reads.
      { name = "ALERT_WEBHOOK_URL", valueFrom = local.secret_arns.alert_webhook_url },
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
      # Unpaused at the 2026-09-10 cutover, after the wrapped-quote smoke test settled with
      # no cash movement on any account. Subaccount 15 is two-sided for the first time --
      # 5000 cNGN and ~3 wrapped USDC -- because the quote leg is the wrapper rather than
      # cash the maker could see but never spend.
      # Paused 2026-09-10 to drain the book for the fee cutover. Pause CANCELS every resting
      # order and idles (execution/bot.go honours it on startup as well as in RunCycle), which is
      # what makes it the drain: the orders on the book were signed with worstFee 0 and would
      # revert TM_FeeTooHigh once the 25 bps schedule is live.
      #
      # It is also the restart. The bot reads /v1/markets once at construction and caches the
      # MarketSpec, so a process that started before the schedule existed keeps signing worstFee 0
      # no matter what the API later says. Unpausing after markets-service ships the schedule is
      # what makes it read taker_fee_bps at all.
      { name = "MM_OPERATOR_MODE", value = "pause" },
      { name = "MM_DRY_RUN", value = "false" },

      { name = "MM_MARKET_SYMBOL", value = "USDCcNGN-SPOT" },
      { name = "MM_OWNER_ADDRESS", value = var.mm_address },
      { name = "MM_SIGNER_ADDRESS", value = var.mm_address },
      # Subaccount 15, not 10. Ten is DeliverableFXManager-managed, and the vault
      # de-whitelisted DFXM on the CashAsset (block 51109818), so every cash adjustment
      # on it now reverts MW_UnknownManager -- the market maker could quote but never
      # settle. Fifteen is SRM-managed, held in Matching custody, and signed by the same
      # MM key, and it holds the cNGN inventory (4999) the maker needs.
      #
      # RECIPIENT_ID must equal SUBACCOUNT_ID. Under a WrappedERC20Asset quote leg the
      # credit side needs an allowance, so a recipient that is not the trading account
      # reverts; keeping them equal is what the venue actually exercises and tests.
      { name = "MM_SUBACCOUNT_ID", value = "15" },
      { name = "MM_RECIPIENT_ID", value = "15" },

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
