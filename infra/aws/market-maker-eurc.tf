# The EURC-USDC spot market maker: Base EURC against USDC under the MarginEngine (market 2), on the same
# TradeModule and USDC cash as cNGN spot. The same mm-bot repository and MM key as the other makers, from its
# own account under the engine, as its own service so it can be stopped or rolled back alone.
#
# Nothing here exists until image_market_maker_eurc is set: the maker is anchored to Chainlink's EURC/USD feed
# (MM_ANCHOR_SOURCE_TYPE=chainlink, a numofx/market-maker change written separately), and an image older than
# that refuses the anchor type at boot, so there is no image to fall back to. While the image is unset there is
# no task definition, no service and no log group: the plan is unchanged.
#
# Operator, after deployment (none of this is a repo default yet; write each back the same day):
#   1. eurc_spot_asset_address  = risk-core deployments/8453/EURC_SPOT.json .escrow (variables.tf). This alone
#      lists the market and makes EURC depositable and withdrawable; it redeploys markets-service, the matcher
#      (apply through with-matcher-mute.sh) and execution-service.
#   2. image_market_maker_eurc  = the first market-maker build with the chainlink anchor (build-and-push.sh).
#   3. mm_eurc_subaccount_id    = the maker's MarginEngine account, opened and funded with EURC and USDC. Adds
#      the account to the settlement canary.
#   4. desired_count_market_maker_eurc = 1, in counts.auto.tfvars (operator-local, git-ignored), last.
# Once each is live, commit it as the variable's default here, as was done for the future maker's #32.

variable "image_market_maker_eurc" {
  description = "The EURC-USDC market maker's mm-bot image, tagged by git SHA: the first market-maker build with MM_ANCHOR_SOURCE_TYPE=chainlink, or later. Empty creates nothing."
  type        = string
  default     = ""
}

variable "mm_eurc_subaccount_id" {
  description = "The EURC-USDC maker's account under the MarginEngine, held by Matching, owned by mm_address, funded with EURC and USDC. Empty keeps the maker at zero replicas and out of the settlement canary."
  type        = string
  default     = ""
}

variable "desired_count_market_maker_eurc" {
  description = "Replicas for the EURC-USDC market maker. One or zero: two would double-quote the same account. Held at 0 while mm_eurc_subaccount_id is empty."
  type        = number
  default     = 0
  validation {
    condition     = var.desired_count_market_maker_eurc <= 1
    error_message = "Two EURC-USDC market makers would quote the same account against each other."
  }
  validation {
    condition     = var.desired_count_market_maker_eurc == 0 || (var.mm_eurc_subaccount_id != "" && var.image_market_maker_eurc != "")
    error_message = "The EURC-USDC market maker needs mm_eurc_subaccount_id and image_market_maker_eurc before it can run."
  }
}

resource "aws_ecs_task_definition" "market_maker_eurc" {
  count                    = var.image_market_maker_eurc == "" ? 0 : 1
  family                   = "${var.name}-market-maker-eurc"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "market-maker-eurc"
    image     = var.image_market_maker_eurc
    essential = true

    environment = [
      { name = "MM_CHAIN_ID", value = var.chain_id },
      { name = "MM_MATCHING_ADDRESS", value = var.matching_address },
      # The spot TradeModule, as the cNGN spot maker: both spot markets settle their quote leg in the same cash.
      { name = "MM_TRADE_MODULE_ADDRESS", value = var.trade_module_address },
      { name = "MM_SUBACCOUNTS_ADDRESS", value = var.subaccounts_address },
      { name = "MM_API_BASE_URL", value = "http://markets-service.${var.internal_namespace}:8080" },

      { name = "MM_OPERATOR_MODE", value = "normal" },
      { name = "MM_DRY_RUN", value = "false" },

      { name = "MM_MARKET_SYMBOL", value = "EURC-USDC" },
      { name = "MM_OWNER_ADDRESS", value = var.mm_address },
      { name = "MM_SIGNER_ADDRESS", value = var.mm_address },
      { name = "MM_SUBACCOUNT_ID", value = var.mm_eurc_subaccount_id },
      { name = "MM_RECIPIENT_ID", value = var.mm_eurc_subaccount_id },

      # Quotes around a live EURC/USDC reference, banded by Chainlink (numofx/market-maker#43). The reference is
      # the 60 s TWAP of the EURC/USDC Slipstream pool, tick spacing 50 (~80% of Base's 2% depth), which moves
      # every block. The band is Chainlink EURC/USD on Base, the 1 h feed (Chainlink's directory: 0.1%
      # deviation, 3,600 s heartbeat, 8 decimals; USD per EURC, read as USDC per EURC): a TWAP more than 50 bps
      # from it halts the bot at once ("anchor out of band") instead of being followed. The other EURC/USD feed,
      # 0xDAe3...8250 (0.3%, 24 h; the venue's collateral oracle), sat ~15 bps from the market on 2026-10-21;
      # the 1 h feed and the pool were 1.9 bps apart. 7,200 s is its heartbeat plus an hour: a missed heartbeat
      # stops the quotes rather than leaving the band on a stale price.
      { name = "MM_ANCHOR_SOURCE_TYPE", value = "chainlink" },
      { name = "MM_ANCHOR_CHAINLINK_FEED", value = "0x9867186e52d2F1C2c565CDA6E747101Fa56501e0" },
      { name = "MM_ANCHOR_CHAINLINK_MAX_AGE_SECONDS", value = "7200" },
      { name = "MM_ANCHOR_POOL_ADDRESS", value = "0xE846373C1a92B167b4E9cd5d8E4d6B1Db9E90EC7" },
      { name = "MM_ANCHOR_POOL_TWAP_SECONDS", value = "60" },
      { name = "MM_ANCHOR_BAND_BPS", value = "50" },
      { name = "MM_USDCCNGN_SPOT_EXTERNAL_ANCHOR_ENABLED", value = "false" },
      # The venue's own book against the reference: past 50 bps the bot stops quoting instead of following it.
      { name = "MM_MAX_ANCHOR_DEVIATION_BPS", value = "50" },
      # How long the feed may be UNREADABLE (RPC down) before the bot halts and cancels. The age of the price
      # itself is MM_ANCHOR_CHAINLINK_MAX_AGE_SECONDS, which halts at once.
      { name = "MM_STALE_ANCHOR_TIMEOUT_SECONDS", value = "300" },

      # Launch size. Units as the bot reads them for EURC-USDC (market-maker README, EURC-USDC units):
      # MM_ORDER_SIZE and the inventory limits in USDC (EURC valued at the reference), MM_MAX_NOTIONAL_PER_SIDE
      # in EURC. Four rungs a side from 5,000 USDC, 1.2x outward: 5,000 + 6,000 + 7,200 + 8,640 = 26,840 USDC
      # a side, ~23,900 EURC at 1.12. 5 bps out and 3 bps further each, so the outer rung is 14 bps out: with
      # the live reference the inner rung sits inside the 1 h feed's 10 bps deviation threshold, which a
      # Chainlink-only anchor could not do without quoting a stale price.
      { name = "MM_ORDER_SIZE", value = "5000" },
      { name = "MM_QUOTE_LEVELS", value = "4" },
      { name = "MM_LEVEL_SIZE_MULT", value = "1.2" },
      { name = "MM_HALF_SPREAD_BPS", value = "5" },
      { name = "MM_LEVEL_SPREAD_STEP_BPS", value = "3" },
      # A halt, not a soft cap (it cancels the ladder), so it covers the worst case: every bid rung fills on top
      # of the EURC held. 56,000 USDC is ~50,000 EURC at 1.12: that worst case for up to ~23,000 EURC of
      # funding; raise it with the funding. LONG/SHORT default to +/-1,000 USDC and NET only tightens them, so
      # all three are set: with NET alone the bot halts past ~890 EURC.
      { name = "MM_MAX_NET_INVENTORY", value = "56000" },
      { name = "MM_MAX_LONG_INVENTORY", value = "56000" },
      { name = "MM_MAX_SHORT_INVENTORY", value = "-56000" },
      # Per side and per order, in EURC: above the ~23,900 EURC ladder and its largest rung (~7,700 EURC), so
      # the ladder rather than this binds.
      { name = "MM_MAX_NOTIONAL_PER_SIDE", value = "30000" },

      # 8 resting quotes; 300 s keeps replacements far inside the cancel cap, as on the other makers.
      { name = "MM_ORDER_EXPIRY_SECONDS", value = "300" },
      { name = "MM_PROTECTED_ORDER_ID_PREFIXES", value = "validation:,smoke:,manual:,test:" },
      { name = "MM_METRICS_ADDR", value = ":8080" },
      { name = "MM_READINESS_MISSING_QUOTE_TIMEOUT_SECONDS", value = "120" },
      { name = "MM_SOAK_LOG_INTERVAL_SECONDS", value = "60" },
      { name = "MM_LOG_LEVEL", value = "INFO" },
      { name = "MM_STATE_FILE", value = "/tmp/.mm-bot-eurc-state.json" },
    ]
    secrets = [
      { name = "MM_OWNER_PRIVATE_KEY", valueFrom = local.secret_arns.mm_private_key },
      { name = "MM_SIGNER_PRIVATE_KEY", valueFrom = local.secret_arns.mm_private_key },
      { name = "MM_RPC_URL", valueFrom = local.secret_arns.mm_rpc_url },
      # The feed is read over the same RPC the cNGN spot maker's anchor uses.
      { name = "MM_ANCHOR_CHAINLINK_RPC_URL", valueFrom = local.secret_arns.mm_rpc_url },
      { name = "MM_DATABASE_URL", valueFrom = local.secret_arns.database_url },
    ]
    healthCheck = {
      command     = ["CMD", "/app/mm-bot", "-healthcheck"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 20
    }

    logConfiguration = local.log_options["market-maker-eurc"]
  }])
}

# Stop before start, as for the other makers: two bots on one book. Held at zero replicas until the account
# is set, whatever counts.auto.tfvars says.
resource "aws_ecs_service" "market_maker_eurc" {
  count           = var.image_market_maker_eurc == "" ? 0 : 1
  name            = "market-maker-eurc"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.market_maker_eurc[0].arn
  desired_count   = var.mm_eurc_subaccount_id == "" ? 0 : var.desired_count_market_maker_eurc
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }
}
