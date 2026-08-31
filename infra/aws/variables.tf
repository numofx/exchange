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
  type    = string
  default = "0x44813aD30b2fFC1bB2871Eed9b19F63c8196eD1c"
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
