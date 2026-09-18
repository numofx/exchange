variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  description = "Prefix for every resource in this stack."
  type        = string
  default     = "numo-exchange"
}

variable "vpc_cidr" {
  # Deliberately not 172.31/16 — that is the account's default VPC, and overlapping
  # ranges make any future peering to it impossible.
  type    = string
  default = "10.20.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "internal_namespace" {
  description = <<-EOT
    Private DNS namespace. Kept as railway.internal on purpose: EXECUTOR_URL and
    DATABASE_URL then carry over from Railway byte-identical, so the cutover changes
    where things run without changing what they are configured to talk to.
  EOT
  type        = string
  default     = "railway.internal"
}

variable "db_instance_class" {
  # 29 MB of data and a paused venue. Right-size up when flow returns, not before.
  type    = string
  default = "db.t4g.micro"
}

variable "db_multi_az" {
  description = "Off for cutover; flip to true once spot has been quoting long enough to care."
  type        = bool
  default     = false
}

variable "api_domain" {
  type    = string
  default = "api.numofx.com"
}

variable "acm_certificate_arn" {
  description = "Existing ACM cert for api_domain in var.region. Must be ISSUED before the ALB applies."
  type        = string
}

variable "image_markets" {
  description = "ECR image URI for the Go binary (serves both api and matcher modes)."
  type        = string
}

variable "image_execution" {
  description = "ECR image URI for services/execution."
  type        = string
}

variable "secret_backend" {
  description = <<-EOT
    Where task secrets are read from. "ssm" matches the convention already in this
    account (/numo/feeds/*, /numo/mark-keeper/* as SecureString) and is the boring
    choice; "secretsmanager" costs more and buys rotation this stack does not use yet.
  EOT
  type        = string
  default     = "ssm"

  validation {
    condition     = contains(["ssm", "secretsmanager"], var.secret_backend)
    error_message = "secret_backend must be \"ssm\" or \"secretsmanager\"."
  }
}

variable "chain_id" {
  type    = string
  default = "8453"
}

variable "matching_address" {
  type    = string
  default = "0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191"
}

variable "trade_module_address" {
  # The module the venue settles on. Every submitted order is now pinned to this address
  # (markets: validateActionModule), so changing it is a hard cutover, not a rolling one:
  # orders resting for the old module stop being matchable the moment this changes.
  #
  # Cutover 2026-09-10: 0x44813aD3 (cash-quoted) -> 0x12423B36 (wrapped-USDC-quoted).
  type    = string
  default = "0x12423B366F6F07130961900bE00d05Ea63Acd071"
}

variable "quote_asset_address" {
  # The asset `trade_module_address` settles the quote leg in, i.e. its quoteAsset(). The
  # markets service reads a buyer's balance of THIS contract before crossing a pair, so it
  # must be changed in the same commit as trade_module_address -- reading the wrong ledger
  # judges every buyer against balances the trade does not touch.
  #
  #   cash-quoted module    0x44813aD3...  ->  CashAsset            0x6B232A2155Bd0C9bf741dB4cf8E7e8A0176A6fc6
  #   wrapped-quote module  0x12423B36...  ->  WRAPPED_USDC_DELIV.  0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84
  #
  # Set at the 2026-09-10 cutover. This also turns the pre-trade funding check ON, which was
  # inert while it was empty -- watch for funding_check_enabled in the markets logs. The
  # matcher additionally reads TradeModule.quoteAsset() at startup and refuses to boot if this
  # disagrees with it, so a half-applied pair fails loudly instead of judging every buyer
  # against a ledger the trade does not touch.
  type    = string
  default = "0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84"
}

variable "cash_asset_address" {
  # The settlement-ledger CashAsset. Only the legacy fallback source of QUOTE_ASSET_ADDRESS;
  # prefer setting quote_asset_address explicitly.
  type    = string
  default = ""
}

variable "ws_allowed_origins" {
  description = "Origins allowed to open /v1/ws. Empty means same-origin only, which breaks the browser app."
  type        = string
  default     = "trade.numofx.com,app.numofx.com"
}

variable "cancel_protected_order_id_prefixes" {
  description = "Order id prefixes that cannot be cancelled through the API."
  type        = string
  default     = "validation:,smoke:,manual:"
}

variable "withdrawal_module_address" {
  # The WithdrawalModule signed withdrawals go through. markets-service pins every withdrawal to it and
  # execution-service submits only to it; Matching must allow it (preflight.sh checks).
  type    = string
  default = "0x0a10AE2f5D2482cE1e43bC309D430B8861C2b5aB"
}

variable "cngn_spot_asset_address" {
  # Losing this silently disables the only market. The boot guard turns that into a
  # crash; keeping it in Terraform keeps it from being lost in the first place.
  type    = string
  default = "0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493"
}

variable "matcher_poll_interval" {
  type    = string
  default = "250ms"
}

# Every service starts at zero replicas on purpose.
#
# The Railway cluster is still live during provisioning, and the executor EOA is
# shared between the two deployments — one nonce sequence, two senders. A task that
# comes up on its own would race Railway for that nonce. The matcher is the same
# hazard one level up: two matchers over two copies of the same book.
#
# So the counts are a deliberate, separate act after Railway is frozen, not a
# side effect of `apply`.
variable "desired_count_markets" {
  description = "Replicas for the markets API. Raise only after Railway is frozen."
  type        = number
  default     = 0
}

variable "desired_count_matcher" {
  description = "Replicas for the matcher. MUST stay 1 or 0 — never above 1."
  type        = number
  default     = 0

  validation {
    condition     = var.desired_count_matcher <= 1
    error_message = "Two matchers would reserve the same book concurrently."
  }
}

variable "desired_count_execution" {
  description = "Replicas for the execution service. Raise only after Railway is frozen."
  type        = number
  default     = 0

  validation {
    condition     = var.desired_count_execution <= 1
    error_message = "The executor EOA has one nonce sequence; only one sender may run."
  }
}

variable "image_market_maker" {
  description = "Fully qualified mm-bot image, tagged by git SHA. Built from numofx/market-maker."
  type        = string
}

variable "subaccounts_address" {
  description = "SubAccounts contract. The market maker resolves it from a sibling repo if unset, so it is set explicitly."
  type        = string
  default     = "0x7019244E25FA416e6Ca2ed2F3cA25277aef72843"
}

variable "desired_count_market_maker" {
  description = "Replicas for the market maker. One or zero — two would double-quote the same subaccount."
  type        = number
  default     = 0

  validation {
    condition     = var.desired_count_market_maker <= 1
    error_message = "Two market makers would quote the same subaccount against each other."
  }
}

variable "mm_address" {
  description = "Market maker owner and signer address (subaccount 10). Must match the key in /numo/exchange/mm_private_key — preflight.sh asserts it."
  type        = string
  default     = "0x3448ac0A3283951A2AFD5B3A582329ECA43CB47B"
}

variable "executor_kms_enabled" {
  description = <<-EOT
    Create the KMS signing key for the trade executor and grant the task role Sign on it.

    Creating the key changes nothing about how the service signs: that is executor_kms_signing.
    The two are separate because the new address must be funded and authorised on Matching with
    setTradeExecutor (owner-only) BEFORE it signs anything, and that happens between the two
    applies.

    Defaults true because the key exists and is authorised on Matching. A plan that resolves
    this to false proposes destroying the venue's settlement key; aws_kms_key.executor carries
    prevent_destroy so that fails loudly instead of succeeding quietly.
  EOT
  type        = bool
  default     = true
}

variable "executor_kms_signing" {
  description = <<-EOT
    Sign settlements with the KMS key: sets EXECUTOR_KMS_KEY_ID on execution-service and drops the
    PRIVATE_KEY secret from the task.

    Flip this only after ALL of:
      1. executor_kms_enabled = true has been applied, so the key exists
      2. the image running execution-service understands EXECUTOR_KMS_KEY_ID (exchange#62 or later)
      3. the key's address holds ETH for gas
      4. Matching.setTradeExecutor(<kms address>, true) has been sent by the owner

    Miss 2 and the task fails its config schema at boot with no PRIVATE_KEY to fall back to. Miss 4
    and every verifyAndMatch reverts with M_OnlyTradeExecutor: the service is signing as an address
    the venue does not recognise.

    Rollback is this flag back to false plus a rollout; the old key stays authorised until it is
    retired deliberately.

    Defaults true because #64 deleted the stored PRIVATE_KEY. There is no second signing path:
    resolved false, execution-service gets neither EXECUTOR_KMS_KEY_ID nor PRIVATE_KEY and
    refuses to boot. The rollout sequence above is history, kept because it explains the split.
  EOT
  type        = bool
  default     = true
}

variable "rebalance_kms_enabled" {
  description = <<-EOT
    Create the KMS signing key the cNGN rebalance uses to swap USDC for cNGN on the HyperFX
    IntentGateway (0xAe041F7B0CB581876832830baeB6a2Aa2a3C9716 on Base).

    Deliberately NOT the executor key. The executor is authorised on Matching by
    setTradeExecutor and settles every trade and withdrawal on the venue; this one only ever
    holds a few hundred dollars of working capital and signs placeOrder. Keeping them apart
    means a compromised rebalance key costs the float, not the venue's settlement authority --
    the same reason the executor was moved off the personal wallet on 2026-09-16.

    Creating the key grants nothing and starts nothing. Until the loop is automated the swap is
    run as a one-shot by an operator, who already holds kms:Sign through their own role, so no
    task role gets Sign on this key yet.
    Defaults true for the same reason as the executor key: it exists, it holds working capital,
    and a plan that resolves it to false proposes deleting it out from under that balance.
  EOT
  type        = bool
  default     = true
}
