# The v2 OnchainBook maker: one SELF-PRICED spline on the v2 book (risk-core ONCHAIN_BOOK_V2.json; spec C4.2, C6) for
# EURC-30NOV26, beside the v1 maker (market-maker-book.tf), which keeps quoting v1 pegged until the same cutoff. Run-sheet:
# risk-core docs/onchain-book-v2-runsheet.md. Same image family and MM key; its own account, service, logs and dead-man
# check, so either maker can be stopped or rolled back alone.
#
# Cadence (owner, 2026-11-17): a 30 s ttl refreshed once 22 s old, a reprice sending at once; the book caps a
# self-priced ttl at 60 s. ~3,500 updates a day at ~73k gas: fund the MM wallet and raise its floor first (run-sheet).
#
# Nothing here exists until image_market_maker_book_v2 is set (an image with book-maker 0d687040 or later: self-priced,
# v1/v2 detection); it runs only with desired_count_market_maker_book_v2 = 1, and sends nothing until
# market_maker_book_v2_dry_run = false.

variable "image_market_maker_book_v2" {
  description = "The market-maker image carrying /app/book-maker with self-priced support (0d687040+), by git SHA. Empty creates nothing."
  type        = string
  default     = ""
}

variable "onchain_book_v2_maker_book" {
  description = "The v2 book the maker quotes (ONCHAIN_BOOK_V2.json .book). Separate from onchain_book_v2_address, the matcher's indexer, so setting one does not redeploy the other."
  type        = string
  default     = ""
  validation {
    condition     = var.onchain_book_v2_maker_book == "" || can(regex("^0x[0-9a-fA-F]{40}$", var.onchain_book_v2_maker_book))
    error_message = "onchain_book_v2_maker_book must be an address or empty."
  }
}

variable "onchain_book_v2_maker_account_id" {
  description = "The v2 maker's account: held by mm_address (not Matching) under MarginEngine v2, with allowances to the v2 book."
  type        = string
  default     = ""
}

# D4 (run-sheet): the size is to be named. Defaults are v1's canary curve.
variable "onchain_book_v2_maker_curve" {
  type    = string
  default = "20@0,40@50"
}

variable "onchain_book_v2_maker_half_spread_ticks" {
  type    = string
  default = "300"
}

variable "market_maker_book_v2_dry_run" {
  description = "true: reads, decides and logs, sends nothing. The first run is a dry run."
  type        = bool
  default     = true
}

variable "desired_count_market_maker_book_v2" {
  description = "Replicas for the v2 OnchainBook maker. One or zero."
  type        = number
  default     = 0
  validation {
    condition     = var.desired_count_market_maker_book_v2 <= 1
    error_message = "One OnchainBook maker per account."
  }
}

resource "aws_ecs_task_definition" "market_maker_book_v2" {
  count                    = var.image_market_maker_book_v2 == "" ? 0 : 1
  family                   = "${var.name}-market-maker-book-v2"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name        = "market-maker-book-v2"
    image       = var.image_market_maker_book_v2
    essential   = true
    entryPoint  = ["/app/book-maker"]
    stopTimeout = 90

    environment = [
      { name = "MM_BOOK_ADDRESS", value = var.onchain_book_v2_maker_book },
      { name = "MM_BOOK_MARKET_ID", value = "1" },
      { name = "MM_BOOK_ACCOUNT_ID", value = var.onchain_book_v2_maker_account_id },
      { name = "MM_BOOK_REFERENCE_MARKET_ID", value = "2" },
      { name = "MM_BOOK_SELF_PRICED", value = "true" },
      { name = "MM_BOOK_CURVE", value = var.onchain_book_v2_maker_curve },
      { name = "MM_BOOK_HALF_SPREAD_TICKS", value = var.onchain_book_v2_maker_half_spread_ticks },
      { name = "MM_BOOK_TTL_SECONDS", value = "30" },
      { name = "MM_BOOK_REFRESH_SECONDS", value = "22" },
      { name = "MM_BOOK_REPRICE_TICKS", value = "20" },
      { name = "MM_BOOK_CUTOFF_SECONDS", value = "3600" },
      { name = "MM_BOOK_MAX_DIVERGENCE_BPS", value = "50" },
      { name = "MM_BOOK_POLL_SECONDS", value = "5" },
      { name = "MM_BOOK_DRY_RUN", value = tostring(var.market_maker_book_v2_dry_run) },
      { name = "MM_SIGNER_BACKEND", value = "local" },
    ]
    secrets = [
      { name = "MM_OWNER_PRIVATE_KEY", valueFrom = local.secret_arns.mm_private_key },
      { name = "MM_RPC_URL", valueFrom = local.secret_arns.rpc_fallback_url },
      { name = "MM_BOOK_HEARTBEAT_URL", valueFrom = local.secret_arns_book_v2.book_maker_v2_heartbeat_url },
    ]

    logConfiguration = local.log_options["market-maker-book-v2"]
  }])

  lifecycle {
    precondition {
      condition     = var.onchain_book_v2_maker_book != "" && var.onchain_book_v2_maker_account_id != ""
      error_message = "set onchain_book_v2_maker_book and onchain_book_v2_maker_account_id with image_market_maker_book_v2."
    }
    precondition {
      condition     = lower(var.onchain_book_v2_maker_book) != "0x8fc63dcb3a173aaf5d2de0f42648d908a519d456"
      error_message = "onchain_book_v2_maker_book is the v1 book: self-priced is refused there."
    }
    precondition {
      condition     = var.onchain_book_v2_maker_account_id != var.onchain_book_maker_account_id
      error_message = "the v2 maker's account is v1's (#56): one account per maker (run-sheet D5)."
    }
  }
}

resource "aws_ecs_service" "market_maker_book_v2" {
  count           = var.image_market_maker_book_v2 == "" ? 0 : 1
  name            = "market-maker-book-v2"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.market_maker_book_v2[0].arn
  desired_count   = var.desired_count_market_maker_book_v2
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }
}
