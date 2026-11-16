# The OnchainBook maker: one oracle-pegged spline on risk-core's OnchainBook for EURC-30NOV26 (market-maker
# cmd/book-maker, docs/book-maker.md; spec Part B). It quotes from #56, an account the MM wallet holds itself under
# MarginEngine v2, outside Matching, and it signs and pays gas for every update. Same image and key as the other
# makers, with the entrypoint overridden; its own service so it can be stopped or rolled back alone.
#
# Not on the ops box: the box may read the MM key only for the length of one apply (ops_box_mm_key_grant).
#
# Nothing here exists until image_market_maker_book is set, and it runs only with
# desired_count_market_maker_book = 1 in counts.auto.tfvars.

variable "image_market_maker_book" {
  description = "The market-maker image carrying /app/book-maker, tagged by git SHA. Empty creates nothing."
  type        = string
  # market-maker b8974faa (2026-11-16): book-maker d6c927a7 (owner-bound splines) in the image.
  default = "957261948743.dkr.ecr.us-east-1.amazonaws.com/numo-exchange/market-maker:b8974faa7020"
}

variable "onchain_book_maker_account_id" {
  description = "The OnchainBook maker's account: held by mm_address itself (not Matching) under MarginEngine v2, with the book's allowances on the future and cash."
  type        = string
  # #56, opened 2026-11-16 with 500 USDC from the EURC-USDC maker's #43.
  default = "56"
}

variable "desired_count_market_maker_book" {
  description = "Replicas for the OnchainBook maker. One or zero: a second would supersede the first (seq), not double-quote, but nothing needs it."
  type        = number
  default     = 0
  validation {
    condition     = var.desired_count_market_maker_book <= 1
    error_message = "One OnchainBook maker per account."
  }
}

resource "aws_ecs_task_definition" "market_maker_book" {
  count                    = var.image_market_maker_book == "" ? 0 : 1
  family                   = "${var.name}-market-maker-book"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name       = "market-maker-book"
    image      = var.image_market_maker_book
    essential  = true
    entryPoint = ["/app/book-maker"]
    # SIGTERM cancels the spline (one transaction, receipt awaited); the default 30 s could cut it off. If it
    # does not land the spline lapses at its ttl.
    stopTimeout = 90

    environment = [
      # risk-core deployments/8453/ONCHAIN_BOOK.json. Not var.onchain_book_address: that is the matcher's indexer, and
      # setting it redeploys the matcher.
      { name = "MM_BOOK_ADDRESS", value = "0x8Fc63DcB3a173aAF5d2de0F42648D908A519d456" },
      { name = "MM_BOOK_MARKET_ID", value = "1" },
      { name = "MM_BOOK_ACCOUNT_ID", value = var.onchain_book_maker_account_id },
      { name = "MM_BOOK_REFERENCE_MARKET_ID", value = "2" },
      # The canary's curve (2026-11-16): 20 EURC at the best level and 40 more 50 ticks behind, each side; a
      # 300-tick half-spread is ~2.7 bps at 1.10. #56's 500 USDC carries it many times over.
      { name = "MM_BOOK_CURVE", value = "20@0,40@50" },
      { name = "MM_BOOK_HALF_SPREAD_TICKS", value = "300" },
      { name = "MM_BOOK_TTL_SECONDS", value = "3600" },
      { name = "MM_BOOK_REFRESH_SECONDS", value = "1800" },
      { name = "MM_BOOK_REPRICE_TICKS", value = "20" },
      { name = "MM_BOOK_CUTOFF_SECONDS", value = "3600" },
      { name = "MM_BOOK_MAX_DIVERGENCE_BPS", value = "50" },
      { name = "MM_BOOK_POLL_SECONDS", value = "5" },
      { name = "MM_BOOK_DRY_RUN", value = "false" },
      { name = "MM_SIGNER_BACKEND", value = "local" },
    ]
    secrets = [
      { name = "MM_OWNER_PRIVATE_KEY", valueFrom = local.secret_arns.mm_private_key },
      { name = "MM_RPC_URL", valueFrom = local.secret_arns.mm_rpc_url },
    ]

    logConfiguration = local.log_options["market-maker-book"]
  }])
}

# Stop before start, as for the other makers: the successor claims the spline with a later seq, and a draining task
# that sees it stops without cancelling (docs/book-maker.md, hand-off).
resource "aws_ecs_service" "market_maker_book" {
  count           = var.image_market_maker_book == "" ? 0 : 1
  name            = "market-maker-book"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.market_maker_book[0].arn
  desired_count   = var.desired_count_market_maker_book
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }
}
