# The USDC-cNGN-30NOV26 market maker: the cNGN future under the MarginEngine, quoted on its own model
# (market-maker #35). The same mm-bot repository and MM key as the spot and perp makers, from its own
# account under the engine, as its own service so it can be stopped or rolled back alone.
#
# Nothing here exists until image_market_maker_future is set: an image older than #35 would quote
# the future on the perp-era model (notional as price x size, no IM sizing, no expiry cutoff), so
# there is no default to fall back to. The replica count stays operator-local
# (desired_count_market_maker_future in counts.auto.tfvars), and needs the account.
#
# The enable batch (propose_margin_engine_batch.py enable) is not to be proposed until this runs and
# quotes both sides. Before enable the series is listed with trading_open false: markets-service
# admits orders (in band, from an engine account) and the matcher does not cross them, so the quotes
# only rest.

variable "image_market_maker_future" {
  description = "The future market maker's mm-bot image, tagged by git SHA: market-maker #35 (6f1b8058) or later. Empty creates nothing."
  type        = string
  # 2026-10-13: market-maker main 135a2f50 (#38: the body's limit_price is the signed one; on df66d7b952ac
  # every order was refused "limitPrice is not aligned with normalized limit_price"), built by build-and-push.sh.
  default = "957261948743.dkr.ecr.us-east-1.amazonaws.com/numo-exchange/market-maker:135a2f508db5"
}

variable "mm_future_subaccount_id" {
  description = <<-EOT
    The market maker's account under the MarginEngine, held by Matching, owned by mm_address: #32,
    opened 2026-10-13 (createAndDepositSubAccount(perp cash, 4,002 USDC, MarginEngine), block 52555670,
    from #24's cash). The venue refuses a futures order from an account under any other manager.
  EOT
  type        = string
  default     = "32"
}

variable "desired_count_market_maker_future" {
  description = "Replicas for the future market maker. One or zero: two would double-quote the same account."
  type        = number
  default     = 0
  validation {
    condition     = var.desired_count_market_maker_future <= 1
    error_message = "Two future market makers would quote the same account against each other."
  }
  validation {
    condition     = var.desired_count_market_maker_future == 0 || (var.mm_future_subaccount_id != "" && var.image_market_maker_future != "")
    error_message = "The future market maker needs mm_future_subaccount_id and image_market_maker_future before it can run."
  }
}

variable "mm_future_carry_rate_apr" {
  description = <<-EOT
    The quote's carry over the future's index: index x e^(rate x time to expiry). 0.118 = 11.8%, the
    NGN 91-day bill (true yield ~16.1%, 2026-10-07 auction) less the US 3-month bill (4.23%,
    2026-10-08), the rate the series' initial mark was deployed at.
  EOT
  type        = string
  default     = "0.118"
}

resource "aws_ecs_task_definition" "market_maker_future" {
  count                    = var.image_market_maker_future == "" ? 0 : 1
  family                   = "${var.name}-market-maker-future"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "market-maker-future"
    image     = var.image_market_maker_future
    essential = true

    environment = [
      { name = "MM_CHAIN_ID", value = var.chain_id },
      { name = "MM_MATCHING_ADDRESS", value = var.matching_address },
      # The future trades on the perp's TradeModule and settles in its cash.
      { name = "MM_TRADE_MODULE_ADDRESS", value = var.cngn_perp_trade_module_address },
      { name = "MM_SUBACCOUNTS_ADDRESS", value = var.subaccounts_address },
      { name = "MM_API_BASE_URL", value = "http://markets-service.${var.internal_namespace}:8080" },

      { name = "MM_OPERATOR_MODE", value = "normal" },
      { name = "MM_DRY_RUN", value = "false" },

      # instruments.FutureSymbol(cngn_future_expiry): the listing's symbol, so it moves with the series.
      { name = "MM_MARKET_SYMBOL", value = "USDC-cNGN-${upper(formatdate("DDMMMYY", timeadd("1970-01-01T00:00:00Z", "${var.cngn_future_expiry}s")))}" },
      { name = "MM_OWNER_ADDRESS", value = var.mm_address },
      { name = "MM_SIGNER_ADDRESS", value = var.mm_address },
      { name = "MM_SUBACCOUNT_ID", value = var.mm_future_subaccount_id },
      { name = "MM_RECIPIENT_ID", value = var.mm_future_subaccount_id },

      # Priced off the future's own index (required on this market) at the deploy's carry.
      { name = "MM_ANCHOR_SOURCE_TYPE", value = "future_index_carry" },
      { name = "MM_CARRY_RATE_APR", value = var.mm_future_carry_rate_apr },
      { name = "MM_USDCCNGN_SPOT_EXTERNAL_ANCHOR_ENABLED", value = "false" },

      # Launch size, against the 30-contract OI cap (15 a side). Sizes and inventory are contracts of
      # 1,000 USDC; notional is USDC. Three rungs of 1, 1.5 and 2.25 contracts a side (4.75, under the
      # 5,000 USDC side cap), 30 bps out and 20 bps further each; inventory bounded at +/- 10 contracts,
      # two thirds of a side. At 25% IM a contract adds 250 USDC of IM: +/- 10 is 2,500, and a full
      # side of resting quotes at MM_FUTURE_IM_USAGE 0.8 needs ~1,500 of surplus on top, so the
      # account wants ~4,000 USDC.
      { name = "MM_ORDER_SIZE", value = "1" },
      { name = "MM_QUOTE_LEVELS", value = "3" },
      { name = "MM_LEVEL_SIZE_MULT", value = "1.5" },
      { name = "MM_HALF_SPREAD_BPS", value = "30" },
      { name = "MM_LEVEL_SPREAD_STEP_BPS", value = "20" },
      { name = "MM_MAX_LONG_INVENTORY", value = "10" },
      { name = "MM_MAX_SHORT_INVENTORY", value = "-10" },
      { name = "MM_MAX_NOTIONAL_PER_SIDE", value = "5000" },
      { name = "MM_INVENTORY_SKEW_BPS", value = "25" },
      { name = "MM_INVENTORY_SKEW_FULL_AT", value = "10" },

      # The futures model's own limits, at market-maker #35's defaults, stated so a changed default
      # cannot move them silently: 80% of the IM surplus, 10 bps inside the fill band, off an hour
      # before the fixing window (or last trade, if earlier).
      { name = "MM_FUTURE_IM_USAGE", value = "0.8" },
      { name = "MM_FUTURE_BAND_BUFFER_BPS", value = "10" },
      { name = "MM_FUTURE_CUTOFF_BEFORE_FIX_SECONDS", value = "3600" },

      # 6 resting quotes replaced before expiry: 300 s keeps that well inside the cancel cap. No order
      # is signed to expire after the cutoff whatever this says.
      { name = "MM_ORDER_EXPIRY_SECONDS", value = "300" },
      { name = "MM_MAX_ANCHOR_DEVIATION_BPS", value = "150" },
      { name = "MM_STALE_ANCHOR_TIMEOUT_SECONDS", value = "1200" },
      { name = "MM_PROTECTED_ORDER_ID_PREFIXES", value = "validation:,smoke:,manual:,test:" },
      { name = "MM_METRICS_ADDR", value = ":8080" },
      { name = "MM_READINESS_MISSING_QUOTE_TIMEOUT_SECONDS", value = "120" },
      { name = "MM_SOAK_LOG_INTERVAL_SECONDS", value = "60" },
      { name = "MM_LOG_LEVEL", value = "INFO" },
      { name = "MM_STATE_FILE", value = "/tmp/.mm-bot-future-state.json" },
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

    logConfiguration = local.log_options["market-maker-future"]
  }])
}

# Stop before start, as for the spot and perp makers: two bots on one book.
resource "aws_ecs_service" "market_maker_future" {
  count           = var.image_market_maker_future == "" ? 0 : 1
  name            = "market-maker-future"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.market_maker_future[0].arn
  desired_count   = var.desired_count_market_maker_future
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }
}
