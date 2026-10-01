# The USDCcNGN-PERP market maker: the same mm-bot image and the same MM key as market-maker-spot,
# quoting the perp from its own account under the perp SRM (go-live checklist step 20). A second
# service rather than a second symbol on the spot one, so each can be stopped, resized or rolled
# back without touching the other's book.
#
# It starts with desired_count 0. The account id is only known once the MM EOA has opened and
# funded it (createAndDepositSubAccount(perpCash, 4,000e6, perpSRM)); set mm_perp_subaccount_id
# and desired_count_market_maker_perp = 1 in the operator-local counts.auto.tfvars together.

variable "mm_perp_subaccount_id" {
  description = "The market maker's perp account under the perp SRM, held by Matching, owned by mm_address. Empty until step 20 opens it."
  type        = string
  default     = ""
}

variable "desired_count_market_maker_perp" {
  description = "Replicas for the perp market maker. One or zero — two would double-quote the same account."
  type        = number
  default     = 0
  validation {
    condition     = var.desired_count_market_maker_perp <= 1
    error_message = "Two perp market makers would quote the same account against each other."
  }
  validation {
    condition     = var.desired_count_market_maker_perp == 0 || var.mm_perp_subaccount_id != ""
    error_message = "The perp market maker needs mm_perp_subaccount_id before it can run."
  }
}

variable "mm_perp_quote_while_closed" {
  description = <<-EOT
    Rest quotes while /v1/markets reports trading_enabled false. True for the launch: the enable
    gate needs a two-sided book of at least $1k within 2% of the index before the vault opens the
    market, and the matcher skips a closed market so the quotes only rest. Set false after step
    22, so a market the guardian closes is not quoted into.
  EOT
  type        = bool
  default     = true
}

resource "aws_ecs_task_definition" "market_maker_perp" {
  family                   = "${var.name}-market-maker-perp"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "market-maker-perp"
    image     = var.image_market_maker
    essential = true

    environment = [
      { name = "MM_CHAIN_ID", value = var.chain_id },
      { name = "MM_MATCHING_ADDRESS", value = var.matching_address },
      # The perp's own TradeModule; the bot checks its quoteAsset() is the perp cash at startup.
      { name = "MM_TRADE_MODULE_ADDRESS", value = var.cngn_perp_trade_module_address },
      { name = "MM_SUBACCOUNTS_ADDRESS", value = var.subaccounts_address },
      { name = "MM_API_BASE_URL", value = "http://markets-service.${var.internal_namespace}:8080" },

      { name = "MM_OPERATOR_MODE", value = "normal" },
      { name = "MM_DRY_RUN", value = "false" },

      { name = "MM_MARKET_SYMBOL", value = "USDCcNGN-PERP" },
      { name = "MM_OWNER_ADDRESS", value = var.mm_address },
      { name = "MM_SIGNER_ADDRESS", value = var.mm_address },
      { name = "MM_SUBACCOUNT_ID", value = var.mm_perp_subaccount_id },
      { name = "MM_RECIPIENT_ID", value = var.mm_perp_subaccount_id },

      # Runbook step 20 (launch size): $4,000 of cash, 1.5x leverage (the SRM allows 3x), so
      # $6,000 gross, and inventory bounded at +/- $6,000 to match. Three $1,000 rungs a side rest
      # $3,000 inside the enable gate's 2% band (it needs $1,000). Sizes and inventory are USDC on
      # the perp. Capital and these limits go up with the OI cap (runbook: Market-maker capital).
      { name = "MM_PERP_MAX_LEVERAGE", value = "1.5" },
      { name = "MM_PERP_QUOTE_WHILE_CLOSED", value = tostring(var.mm_perp_quote_while_closed) },
      { name = "MM_ORDER_SIZE", value = "1000" },
      { name = "MM_MAX_LONG_INVENTORY", value = "6000" },
      { name = "MM_MAX_SHORT_INVENTORY", value = "-6000" },
      { name = "MM_QUOTE_LEVELS", value = "3" },
      { name = "MM_HALF_SPREAD_BPS", value = "25" },
      { name = "MM_LEVEL_SPREAD_STEP_BPS", value = "25" },
      { name = "MM_LEVEL_SIZE_MULT", value = "1.0" },
      # The reference is the venue's own index (the /v1/markets perp block); no external anchor.
      { name = "MM_ANCHOR_SOURCE_TYPE", value = "none" },
      { name = "MM_USDCCNGN_SPOT_EXTERNAL_ANCHOR_ENABLED", value = "false" },
      { name = "MM_MAX_ANCHOR_DEVIATION_BPS", value = "150" },
      { name = "MM_STALE_ANCHOR_TIMEOUT_SECONDS", value = "1200" },
      { name = "MM_PROTECTED_ORDER_ID_PREFIXES", value = "validation:,smoke:,manual:,test:" },
      { name = "MM_METRICS_ADDR", value = ":8080" },
      { name = "MM_READINESS_MISSING_QUOTE_TIMEOUT_SECONDS", value = "120" },
      { name = "MM_SOAK_LOG_INTERVAL_SECONDS", value = "60" },
      { name = "MM_LOG_LEVEL", value = "INFO" },
      { name = "MM_STATE_FILE", value = "/tmp/.mm-bot-perp-state.json" },
    ]
    secrets = [
      { name = "MM_OWNER_PRIVATE_KEY", valueFrom = local.secret_arns.mm_private_key },
      { name = "MM_SIGNER_PRIVATE_KEY", valueFrom = local.secret_arns.mm_private_key },
      { name = "MM_RPC_URL", valueFrom = local.secret_arns.mm_rpc_url },
      { name = "MM_DATABASE_URL", valueFrom = local.secret_arns.database_url },
    ]
    healthCheck = {
      command     = ["CMD", "/app/mm-bot", "-healthcheck"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 20
    }

    logConfiguration = local.log_options["market-maker-perp"]
  }])
}

# Stop before start, for the same reason as the spot maker: two bots on one book.
resource "aws_ecs_service" "market_maker_perp" {
  name            = "market-maker-perp"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.market_maker_perp.arn
  desired_count   = var.desired_count_market_maker_perp
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }
}
