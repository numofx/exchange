# The cNGN options maker: every listed strike of cNGN-30NOV26 (MarginEngine v2's OptionAsset, ten strike-sides) quoted by
# one mm-bot in options mode (MM_OPTION_SERIES, market-maker #45: 697d70e9 or later) from one account under the v2
# engine, with the same MM key as the other makers. Each strike is priced as the engine marks it (Black-76 on the
# engine's forward and the published vol surface), 3 vol points either side, skewed against the account's net delta.
# scripts/local-venue/options-fork.sh runs this image against production's venue config on a fork.
#
# Nothing runs until the account is set (mm_options_subaccount_id, opened with migrate-spot-mm.ts engine-account
# --market=cNGN-30NOV26: the options share that future's engine and cash) and the replica count is 1
# (desired_count_market_maker_options, operator-local in counts.auto.tfvars). mm_options_dry_run logs what it would
# sign and signs nothing.

variable "image_market_maker_options" {
  description = "The options maker's mm-bot image, tagged by git SHA: market-maker 697d70e9 or later. Empty creates nothing."
  type        = string
  # market-maker main 697d70e9 (options mode, per-strike pool cap), built by build-and-push.sh 2026-11-02.
  # 2026-11-04: 697d70e95773 plus the /v1 path change and the fee-schedule fix only (market-maker tag deploy/mm-options-fee-fix), so no strategy change.
  default = "957261948743.dkr.ecr.us-east-1.amazonaws.com/numo-exchange/market-maker:63616ac6b7ea"
}

variable "mm_options_subaccount_id" {
  description = "The options maker's account under the v2 MarginEngine, held by Matching, owned by mm_address. Empty keeps it at zero replicas."
  type        = string
  # Opened 2026-11-02 (engine-account --market=cNGN-30NOV26, under the MM-key grant; create 0x603e928e…, block
  # 53400565) and funded with 1,000 USDC moved from #43 (move-usdc: withdraw 0x953afdbe…, deposit 0xa2a744cb…, block
  # 53400596). #44: 1,000.05 USDC, IM surplus 1,000.05.
  default = "44"
}

variable "desired_count_market_maker_options" {
  description = "Replicas for the options maker. One or zero: two would quote the same account against each other."
  type        = number
  default     = 0
  validation {
    condition     = var.desired_count_market_maker_options <= 1
    error_message = "Two options makers would quote the same account against each other."
  }
}

variable "mm_options_dry_run" {
  description = "The options maker logs the quotes it would sign and signs none. True until its quotes read right on mainnet."
  type        = bool
  # 2026-11-02 03:38-04:02 UTC in dry run on #44: ten strikes priced, quotes followed time decay each cycle and the
  # 5-minute forward/vol publishes (ATM put 0.0000290 / 0.0000338 around 0.0000313), no error or halt. Live since.
  default = false
}

locals {
  mm_options_enabled = var.image_market_maker_options == "" ? {} : { options = true }
}

resource "aws_ecs_task_definition" "market_maker_options" {
  for_each                 = local.mm_options_enabled
  family                   = "${var.name}-market-maker-options"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "market-maker-options"
    image     = var.image_market_maker_options
    essential = true

    environment = [
      { name = "MM_CHAIN_ID", value = var.chain_id },
      { name = "MM_MATCHING_ADDRESS", value = var.matching_address },
      # The options trade on the perp's TradeModule and settle premium in its cash, as the v2 futures do.
      { name = "MM_TRADE_MODULE_ADDRESS", value = var.cngn_perp_trade_module_address },
      { name = "MM_SUBACCOUNTS_ADDRESS", value = var.subaccounts_address },
      { name = "MM_API_BASE_URL", value = "http://markets-service.${var.internal_namespace}:8080" },

      { name = "MM_OPERATOR_MODE", value = "normal" },
      { name = "MM_DRY_RUN", value = tostring(var.mm_options_dry_run) },

      # Options mode: every listed strike of the series, discovered from /markets. MM_MARKET_SYMBOL only names the
      # process in its config; each strike is its own market inside it.
      { name = "MM_OPTION_SERIES", value = "cNGN-30NOV26" },
      { name = "MM_MARKET_SYMBOL", value = "cNGN-30NOV26-0.00072-P" },
      { name = "MM_OWNER_ADDRESS", value = var.mm_address },
      { name = "MM_SIGNER_ADDRESS", value = var.mm_address },
      { name = "MM_SUBACCOUNT_ID", value = var.mm_options_subaccount_id },
      { name = "MM_RECIPIENT_ID", value = var.mm_options_subaccount_id },

      # Decided 2026-11-01 (scope): 3 vol points a side, never under 0.0000005 USDC per cNGN; 100k cNGN a side per
      # strike, at most 200k held either way per strike (writing 100k takes $19-32 of IM); half the IM surplus for a
      # written side; off the book 30 minutes before last trade; a degraded surface widens 2x; delta skew only.
      { name = "MM_OPTION_HALF_SPREAD_VOL", value = "0.03" },
      { name = "MM_OPTION_MIN_HALF_SPREAD", value = "0.0000005" },
      { name = "MM_OPTION_ORDER_SIZE", value = "100000" },
      { name = "MM_OPTION_MAX_POSITION", value = "200000" },
      { name = "MM_OPTION_IM_USAGE", value = "0.5" },
      { name = "MM_OPTION_CUTOFF_SECONDS", value = "1800" },
      { name = "MM_OPTION_DEGRADED_SPREAD_MULTIPLIER", value = "2" },
      { name = "MM_OPTION_DELTA_SKEW_BPS", value = "50" },
      { name = "MM_OPTION_DELTA_FULL_AT", value = "500000" },
      # The risk layer's own bound per strike, in cNGN, above the strategy's 200k so the strategy binds first.
      { name = "MM_MAX_LONG_INVENTORY", value = "300000" },
      { name = "MM_MAX_SHORT_INVENTORY", value = "-300000" },

      { name = "MM_ORDER_EXPIRY_SECONDS", value = "300" },
      { name = "MM_PROTECTED_ORDER_ID_PREFIXES", value = "validation:,smoke:,manual:,test:" },
      { name = "MM_METRICS_ADDR", value = ":8080" },
      { name = "MM_READINESS_MISSING_QUOTE_TIMEOUT_SECONDS", value = "120" },
      { name = "MM_SOAK_LOG_INTERVAL_SECONDS", value = "60" },
      { name = "MM_LOG_LEVEL", value = "INFO" },
      { name = "MM_STATE_FILE", value = "/tmp/.mm-bot-options-state.json" },
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
      startPeriod = 30
    }

    logConfiguration = local.log_options["market-maker-options"]
  }])
}

# Stop before start, as for the other makers: two bots on one book.
resource "aws_ecs_service" "market_maker_options" {
  for_each        = local.mm_options_enabled
  name            = "market-maker-options"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.market_maker_options[each.key].arn
  desired_count   = var.mm_options_subaccount_id == "" ? 0 : var.desired_count_market_maker_options
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }
}
