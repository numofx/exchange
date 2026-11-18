# The cNGN OnchainBook maker: one SELF-PRICED spline on the adapter-less cNGN book (risk-core ONCHAIN_BOOK_CNGN.json,
# 2026-11-18) for cNGN-30NOV26. Owner's decision 2026-11-18: move the cNGN future onto the on-chain book, funded from
# #39 (the Matching maker, stopped at cutover).
#
# Its own wallet (0x7b96…bE4d, /numo/exchange/mm_book_cngn_private_key), account #60, service and logs: the EURC book
# maker sends from the MM wallet, and two makers on one key collide on nonces.
#
# REFERENCE. The engine's only cNGN price is the index itself, so the divergence guard reads a sidecar,
# cngn-rate (services/cngn-rate: cngn-rate-picker's USDC corridors), at 127.0.0.1:8787. NOT fully independent: the
# index is built from the same library's USDT providers. A dead sidecar takes the spline down. 200 bps: the two read
# ~55 bps apart on 2026-11-18, past EURC's 50.
#
# Units: tick 1e10 (0.00000001 USDC; ~6.87 ticks a bp at 0.000687), lot 1e15 (0.001 contract, 1,000 cNGN). The curve
# mirrors #39's Matching ladder (0.116 contracts x1.2, 10 rungs; 15 bps half spread, 5 bps steps).
#
# Nothing exists until image_cngn_rate is set; it runs only with desired_count_market_maker_book_cngn = 1 and sends
# nothing until market_maker_book_cngn_dry_run = false.

variable "image_cngn_rate" {
  description = "The cngn-rate sidecar image (services/cngn-rate), by git SHA. Empty creates nothing here."
  type        = string
  # services/cngn-rate at c39ec112 (2026-11-18)
  default = "957261948743.dkr.ecr.us-east-1.amazonaws.com/numo-exchange/cngn-rate:c39ec1128990"
}

variable "image_market_maker_book_cngn" {
  description = "The market-maker image carrying /app/book-maker with MM_BOOK_REFERENCE_URL (0f8c5b26+), by git SHA."
  type        = string
  default     = "957261948743.dkr.ecr.us-east-1.amazonaws.com/numo-exchange/market-maker:0f8c5b262781"
}

variable "onchain_book_cngn_maker_book" {
  description = "The cNGN book (ONCHAIN_BOOK_CNGN.json .book)."
  type        = string
  # Deployed 2026-11-18; setup landed (vault owns it, 0x7b96… allowed); market disabled until the enable batch.
  default = "0x5a35f149005Ce74b874F7Cf07CC2618BFA4F8Bd4"
}

variable "onchain_book_cngn_maker_account_id" {
  description = "The cNGN maker's account: held by 0x7b96…bE4d (not Matching) under MarginEngine v2."
  type        = string
  # #60, created 2026-11-18 (0xdff5f63e…); 2,700 USDC from #39 at cutover.
  default = "60"
}

variable "market_maker_book_cngn_dry_run" {
  description = "true: reads, decides and logs, sends nothing. The first run is a dry run."
  type        = bool
  # Dry run 2026-11-18 23:06 UTC (preflight ok, mid 68,707); live 23:2x after #39 stopped and 2,700 USDC moved to #60.
  default = false
}

variable "desired_count_market_maker_book_cngn" {
  description = "Replicas for the cNGN OnchainBook maker. One or zero."
  type        = number
  default     = 0
  validation {
    condition     = var.desired_count_market_maker_book_cngn <= 1
    error_message = "One OnchainBook maker per account."
  }
}

locals {
  book_cngn_enabled = var.image_cngn_rate != "" && var.image_market_maker_book_cngn != ""
}

resource "aws_ecs_task_definition" "market_maker_book_cngn" {
  count                    = local.book_cngn_enabled ? 1 : 0
  family                   = "${var.name}-market-maker-book-cngn"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name        = "market-maker-book-cngn"
      image       = var.image_market_maker_book_cngn
      essential   = true
      entryPoint  = ["/app/book-maker"]
      stopTimeout = 90
      dependsOn   = [{ containerName = "cngn-rate", condition = "HEALTHY" }]

      environment = [
        { name = "MM_BOOK_ADDRESS", value = var.onchain_book_cngn_maker_book },
        { name = "MM_BOOK_MARKET_ID", value = "1" },
        { name = "MM_BOOK_ACCOUNT_ID", value = var.onchain_book_cngn_maker_account_id },
        { name = "MM_BOOK_REFERENCE_URL", value = "http://127.0.0.1:8787/usd-per-cngn" },
        { name = "MM_BOOK_REFERENCE_MAX_AGE_SECONDS", value = "300" },
        { name = "MM_BOOK_SELF_PRICED", value = "true" },
        # #39's ladder: 116 lots x1.2, ten rungs, 5 bps (34 ticks) apart; 15 bps (103 ticks) half spread
        { name = "MM_BOOK_CURVE", value = "116@0,139@34,167@69,200@103,241@137,289@172,346@206,416@240,499@275,599@309" },
        { name = "MM_BOOK_HALF_SPREAD_TICKS", value = "103" },
        # 10 contracts: the future's OI cap is 30 in all
        { name = "MM_BOOK_MAX_POSITION_LOTS", value = "10000" },
        # 1 tick a lot to 25 bps (172 ticks): the tick is coarse against the lot, so full skew comes at ~0.17 contract
        { name = "MM_BOOK_SKEW_TICKS_PER_LOT", value = "1" },
        { name = "MM_BOOK_MAX_SKEW_TICKS", value = "172" },
        # 60 s / 50 s (owner, 2026-11-18: 0.01 ETH to expiry): ~1,700 sends a day, ~0.0008 ETH, half EURC's 30/22.
        # The book caps a self-priced ttl at 60; 50 + 5 poll + 3 inside it (CheckCadence).
        { name = "MM_BOOK_TTL_SECONDS", value = "60" },
        { name = "MM_BOOK_REFRESH_SECONDS", value = "50" },
        { name = "MM_BOOK_REPRICE_TICKS", value = "7" }, # ~1 bp
        { name = "MM_BOOK_CUTOFF_SECONDS", value = "3600" },
        { name = "MM_BOOK_MAX_DIVERGENCE_BPS", value = "200" },
        { name = "MM_BOOK_POLL_SECONDS", value = "5" },
        { name = "MM_BOOK_DRY_RUN", value = tostring(var.market_maker_book_cngn_dry_run) },
        { name = "MM_SIGNER_BACKEND", value = "local" },
      ]
      secrets = [
        { name = "MM_OWNER_PRIVATE_KEY", valueFrom = local.secret_arns_book_cngn.mm_book_cngn_private_key },
        { name = "MM_RPC_URL", valueFrom = local.secret_arns.rpc_fallback_url },
      ]
      logConfiguration = local.log_options["market-maker-book-cngn"]
    },
    {
      name      = "cngn-rate"
      image     = var.image_cngn_rate
      essential = true
      environment = [
        { name = "PORT", value = "8787" },
        { name = "MAX_AGE_SECONDS", value = "300" },
        { name = "REFRESH_SECONDS", value = "30" },
      ]
      healthCheck = {
        command     = ["CMD", "node", "-e", "fetch('http://127.0.0.1:8787/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }
      logConfiguration = local.log_options["cngn-rate"]
    },
  ])

  lifecycle {
    precondition {
      condition     = lower(var.onchain_book_cngn_maker_book) != lower(var.onchain_book_v2_maker_book)
      error_message = "the cNGN maker's book is the EURC v2 book."
    }
    precondition {
      condition     = var.onchain_book_cngn_maker_account_id != var.onchain_book_v2_maker_account_id
      error_message = "the cNGN maker's account is the EURC book maker's (#58): one account per maker."
    }
  }
}

resource "aws_ecs_service" "market_maker_book_cngn" {
  count           = local.book_cngn_enabled ? 1 : 0
  name            = "market-maker-book-cngn"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.market_maker_book_cngn[0].arn
  desired_count   = var.desired_count_market_maker_book_cngn
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }
}
