# The MarginEngine v2 market makers: cNGN-30NOV26 and EURC-30NOV26, one service each, under the v2 engine
# (0x0705…0950). The same mm-bot repository and MM key as the other makers, each from its own account under
# that engine, so either can be stopped or rolled back alone. Both series are quoted in American terms (USDC
# per base), a contract's USDC value moving with price (market-maker #44); an older image reads the index
# inverted and sizes margin on a fixed USDC contract, so there is no default to fall back to.
#
# Nothing here exists until image_market_maker_future_v2 is set. A series' service runs only once its
# account is set (mm_future_v2_subaccount_ids, opened with migrate-spot-mm.ts engine-account --market=<symbol>
# under the MM-key grant) and its replica count is 1 (desired_count_market_maker_future_v2, operator-local in
# counts.auto.tfvars). Both start in dry run (mm_future_v2_dry_run): the bot reads the series and the account
# and logs the ladder it would sign, without signing.
#
# Before the enable batch the series are listed with trading_open false: markets-service admits orders (in
# band, from an account under the series' engine) and the matcher does not cross them, so live quotes only
# rest. The enable is not proposed until both quote both sides.

variable "image_market_maker_future_v2" {
  description = "The v2 futures makers' mm-bot image, tagged by git SHA: market-maker #44 (364dbfe3) or later. Empty creates nothing."
  type        = string
  # market-maker main with #44 (American-terms series), built by build-and-push.sh 2026-10-31.
  default = "957261948743.dkr.ecr.us-east-1.amazonaws.com/numo-exchange/market-maker:364dbfe3afd6"
}

variable "mm_future_v2_subaccount_ids" {
  description = "Each v2 maker's account under the v2 MarginEngine, held by Matching, owned by mm_address, keyed cngn and eurc. Empty keeps that maker at zero replicas."
  type        = map(string)
  # Opened 2026-10-31 with 0.10 USDC each (engine-account --market, under the MM-key grant), blocks 53332502/05.
  default = { cngn = "39", eurc = "40" }
  validation {
    condition     = toset(keys(var.mm_future_v2_subaccount_ids)) == toset(["cngn", "eurc"])
    error_message = "mm_future_v2_subaccount_ids is keyed cngn and eurc."
  }
}

variable "desired_count_market_maker_future_v2" {
  description = "Replicas for each v2 maker, keyed cngn and eurc. One or zero: two would double-quote the same account."
  type        = map(number)
  default     = { cngn = 0, eurc = 0 }
  validation {
    condition     = alltrue([for n in values(var.desired_count_market_maker_future_v2) : n <= 1])
    error_message = "Two makers on one series would quote the same account against each other."
  }
  validation {
    condition = alltrue([
      for k, n in var.desired_count_market_maker_future_v2 :
      n == 0 || (lookup(var.mm_future_v2_subaccount_ids, k, "") != "" && var.image_market_maker_future_v2 != "")
    ])
    error_message = "A v2 maker needs its account in mm_future_v2_subaccount_ids and image_market_maker_future_v2 before it can run."
  }
}

variable "mm_future_v2_dry_run" {
  description = "Both v2 makers log the orders they would sign and sign none. Set false once the dry run's ladder reads right."
  type        = bool
  default     = true
}

locals {
  # Per series. Sizes and inventory are contracts, rounded to the venue's 0.001-contract unit; notional is USDC.
  #
  # cNGN-30NOV26: a contract is 1,000,000 cNGN, about 722 USDC at a 0.000722 mark. The future trades at a
  # discount to the index (USDC per cNGN): carry -0.118, the v1 series' 11.8% (NGN 91-day bill less the US
  # 3-month bill) with the sign of American terms. The v1 maker's ladder: ten rungs from 0.116 contract,
  # 1.2x outward, about 3 contracts (2,200 USDC) a side, 15 bps out and 5 bps further each. Inventory within
  # +/- 15, one side of the 30-contract cap. At 25% IM a contract takes about 180 USDC: 15 held is 2,700.
  #
  # EURC-30NOV26: a contract is 1,000 EURC, about 1,117 USDC. Carry 0.015, the USD bill over the EUR one. The
  # same ten rungs, about 3 contracts (3,350 USDC) a side, tighter: 8 bps out and 3 bps further each (35 bps at
  # the outer rung; EURC spot quotes 5 bps out). Inventory within +/- 9, one side of the 18-contract cap. At 6%
  # IM a contract takes about 67 USDC: 9 held is 600.
  mm_future_v2 = {
    cngn = {
      symbol        = "cNGN-30NOV26"
      carry         = "-0.118"
      half_spread   = "15"
      spread_step   = "5"
      max_inventory = "15"
      skew_full_at  = "10"
    }
    eurc = {
      symbol        = "EURC-30NOV26"
      carry         = "0.015"
      half_spread   = "8"
      spread_step   = "3"
      max_inventory = "9"
      skew_full_at  = "6"
    }
  }
  mm_future_v2_enabled = var.image_market_maker_future_v2 == "" ? {} : local.mm_future_v2
}

resource "aws_ecs_task_definition" "market_maker_future_v2" {
  for_each                 = local.mm_future_v2_enabled
  family                   = "${var.name}-market-maker-future-v2-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "market-maker-future-v2-${each.key}"
    image     = var.image_market_maker_future_v2
    essential = true

    environment = [
      { name = "MM_CHAIN_ID", value = var.chain_id },
      { name = "MM_MATCHING_ADDRESS", value = var.matching_address },
      # The v2 series trade on the perp's TradeModule and settle in its cash, as the v1 future does.
      { name = "MM_TRADE_MODULE_ADDRESS", value = var.cngn_perp_trade_module_address },
      { name = "MM_SUBACCOUNTS_ADDRESS", value = var.subaccounts_address },
      { name = "MM_API_BASE_URL", value = "http://markets-service.${var.internal_namespace}:8080" },

      { name = "MM_OPERATOR_MODE", value = "normal" },
      { name = "MM_DRY_RUN", value = tostring(var.mm_future_v2_dry_run) },

      { name = "MM_MARKET_SYMBOL", value = each.value.symbol },
      { name = "MM_OWNER_ADDRESS", value = var.mm_address },
      { name = "MM_SIGNER_ADDRESS", value = var.mm_address },
      { name = "MM_SUBACCOUNT_ID", value = var.mm_future_v2_subaccount_ids[each.key] },
      { name = "MM_RECIPIENT_ID", value = var.mm_future_v2_subaccount_ids[each.key] },

      # Priced off the series' own index at its carry (required on an engine future).
      { name = "MM_ANCHOR_SOURCE_TYPE", value = "future_index_carry" },
      { name = "MM_CARRY_RATE_APR", value = each.value.carry },
      { name = "MM_USDCCNGN_SPOT_EXTERNAL_ANCHOR_ENABLED", value = "false" },

      { name = "MM_ORDER_SIZE", value = "0.116" },
      { name = "MM_QUOTE_LEVELS", value = "10" },
      { name = "MM_LEVEL_SIZE_MULT", value = "1.2" },
      { name = "MM_HALF_SPREAD_BPS", value = each.value.half_spread },
      { name = "MM_LEVEL_SPREAD_STEP_BPS", value = each.value.spread_step },
      { name = "MM_MAX_LONG_INVENTORY", value = each.value.max_inventory },
      { name = "MM_MAX_SHORT_INVENTORY", value = "-${each.value.max_inventory}" },
      { name = "MM_MAX_NOTIONAL_PER_SIDE", value = "10000" },
      { name = "MM_INVENTORY_SKEW_BPS", value = "25" },
      { name = "MM_INVENTORY_SKEW_FULL_AT", value = each.value.skew_full_at },

      # The futures model's limits, as the v1 maker states them.
      { name = "MM_FUTURE_IM_USAGE", value = "0.8" },
      { name = "MM_FUTURE_BAND_BUFFER_BPS", value = "10" },
      { name = "MM_FUTURE_CUTOFF_BEFORE_FIX_SECONDS", value = "3600" },

      { name = "MM_ORDER_EXPIRY_SECONDS", value = "300" },
      { name = "MM_MAX_ANCHOR_DEVIATION_BPS", value = "150" },
      { name = "MM_STALE_ANCHOR_TIMEOUT_SECONDS", value = "1200" },
      { name = "MM_PROTECTED_ORDER_ID_PREFIXES", value = "validation:,smoke:,manual:,test:" },
      { name = "MM_METRICS_ADDR", value = ":8080" },
      { name = "MM_READINESS_MISSING_QUOTE_TIMEOUT_SECONDS", value = "120" },
      { name = "MM_SOAK_LOG_INTERVAL_SECONDS", value = "60" },
      { name = "MM_LOG_LEVEL", value = "INFO" },
      { name = "MM_STATE_FILE", value = "/tmp/.mm-bot-future-v2-${each.key}-state.json" },
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

    logConfiguration = local.log_options["market-maker-future-v2-${each.key}"]
  }])
}

# Stop before start, as for the other makers: two bots on one book.
resource "aws_ecs_service" "market_maker_future_v2" {
  for_each        = local.mm_future_v2_enabled
  name            = "market-maker-future-v2-${each.key}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.market_maker_future_v2[each.key].arn
  desired_count   = var.mm_future_v2_subaccount_ids[each.key] == "" ? 0 : var.desired_count_market_maker_future_v2[each.key]
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }
}
