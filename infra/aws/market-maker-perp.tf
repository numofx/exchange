# The USDCcNGN-PERP market maker: the same mm-bot image and the same MM key as market-maker-spot,
# quoting the perp from its own account under the perp SRM (go-live checklist step 20). A second
# service rather than a second symbol on the spot one, so each can be stopped, resized or rolled
# back without touching the other's book.
#
# The account is #24, opened and funded by the MM EOA on 2026-10-01
# (createAndDepositSubAccount(perpCash, 4,000e6, perpSRM)). The replica count stays operator-local
# (desired_count_market_maker_perp in counts.auto.tfvars); the account id is a default here.

variable "mm_perp_subaccount_id" {
  description = "The market maker's perp account under the perp SRM, held by Matching, owned by mm_address. Opened at step 20 (2026-10-01)."
  type        = string
  default     = "24"
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
    market, and the matcher skips a closed market so the quotes only rest. False since step 22
    (2026-10-01), so a market the guardian closes is not quoted into.
  EOT
  type        = bool
  default     = false
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
      # $6,000 gross, and inventory bounded at +/- $6,000 to match. Ten rungs a side, 116 growing
      # 1.2x per rung (15 bps out, 10 bps further each), rest ~$3,011 a side within 105 bps -- inside
      # the enable gate's 2% band (it needs $1,000). Sizes and inventory are USDC on the perp.
      # Capital and these limits go up with the OI cap (runbook: Market-maker capital).
      { name = "MM_PERP_MAX_LEVERAGE", value = "1.5" },
      { name = "MM_PERP_QUOTE_WHILE_CLOSED", value = tostring(var.mm_perp_quote_while_closed) },
      { name = "MM_ORDER_SIZE", value = "116" },
      { name = "MM_MAX_LONG_INVENTORY", value = "6000" },
      { name = "MM_MAX_SHORT_INVENTORY", value = "-6000" },
      { name = "MM_QUOTE_LEVELS", value = "10" },
      { name = "MM_HALF_SPREAD_BPS", value = "15" },
      { name = "MM_LEVEL_SPREAD_STEP_BPS", value = "10" },
      { name = "MM_LEVEL_SIZE_MULT", value = "1.2" },
      # The inventory lean is what moves funding: PerpAsset pays a premium only once an impact price
      # crosses the index. With perp-feeds IMPACT_NOTIONAL_USD=100 (inside the first rung) that is
      # the 15 bps half spread, so funding leaves the static rate at ~$1,200 of position and reaches
      # ~1.25 bps/h (~110% APR) beyond it at $2,000 (market-maker #33).
      { name = "MM_INVENTORY_SKEW_BPS", value = "25" },
      { name = "MM_INVENTORY_SKEW_FULL_AT", value = "2000" },
      # 20 resting quotes replaced 15 s before expiry: 300 s keeps that at ~4 cancels/min against
      # the 30/min cap (60 s would be ~27/min and skip replaces).
      { name = "MM_ORDER_EXPIRY_SECONDS", value = "300" },
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
