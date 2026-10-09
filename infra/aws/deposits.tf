# Sponsored deposits: POST /v1/deposits on markets-service, submitted by execution-service through the deployed
# DepositModule with the executor paying gas (numofx/exchange#147, #148). Off unless deposits_enabled: with it false
# neither task definition gains a variable, so this file plans as no change.
#
# The gas is paid by the existing executor EOA (the KMS key that settles trades and withdrawals). Top it up before
# enabling; the perp pager's low-gas-executor check pages below its floor. Rolling deposits off is a redeploy: turn
# markets-service off first, wait for its old task to STOP (wait-for-rollout.sh), then execution-service.

variable "deposits_enabled" {
  description = "Serve POST /v1/deposits. Both services read it at boot."
  type        = bool
  default     = false
}

variable "deposit_module_address" {
  description = "The DepositModule every signed deposit must target (contracts/execution deployments/8453/matching.json .deposit)."
  type        = string
  default     = "0x6540f8d9Eb599b045C05E45cb6a5B1730a806658"
}

variable "deposit_min_amount" {
  description = "Smallest deposit, in 6-decimal USDC base units. 10000000 is 10 USDC."
  type        = string
  default     = "10000000"
}

variable "deposit_max_per_hour" {
  description = "Sponsored deposits the executor broadcasts per rolling hour across all owners; past it, 503."
  type        = number
  default     = 20
}

variable "deposits_per_owner_per_minute" {
  description = "Deposit requests one owner may make a minute (markets-service; every attempt counts)."
  type        = number
  default     = 3
}

variable "deposits_per_owner_per_hour" {
  description = "Deposits one owner may have submitted to the executor per rolling hour (refused requests do not count)."
  type        = number
  default     = 6
}

locals {
  # Only the perp CashAsset is depositable and only under the perp SRM: the chain also accepts the cNGN escrow, so
  # the allowlist is what refuses it. Both come from the perp stack's own variables.
  markets_deposit_env = var.deposits_enabled ? [
    { name = "DEPOSITS_ENABLED", value = "true" },
    { name = "DEPOSIT_MODULE_ADDRESS", value = var.deposit_module_address },
    { name = "DEPOSIT_ASSET_ADDRESSES", value = var.cngn_perp_cash_address },
    { name = "DEPOSIT_MANAGER_ADDRESS", value = var.cngn_perp_srm_address },
    { name = "DEPOSIT_MIN_AMOUNT", value = var.deposit_min_amount },
    { name = "DEPOSITS_PER_OWNER_PER_MINUTE", value = tostring(var.deposits_per_owner_per_minute) },
    { name = "DEPOSITS_PER_OWNER_PER_HOUR", value = tostring(var.deposits_per_owner_per_hour) },
    { name = "EXECUTOR_DEPOSIT_URL", value = "http://execution-service.${var.internal_namespace}:8081/deposit" },
    # Must outlast execution-service's DEPOSIT_RECEIPT_TIMEOUT_MS below (plus a permit's own receipt wait).
    { name = "EXECUTOR_DEPOSIT_TIMEOUT", value = "45s" },
  ] : []

  execution_deposit_env = var.deposits_enabled ? [
    { name = "DEPOSITS_ENABLED", value = "true" },
    { name = "DEPOSIT_MODULE_ADDRESS", value = var.deposit_module_address },
    { name = "DEPOSIT_ASSET_ADDRESSES", value = var.cngn_perp_cash_address },
    { name = "DEPOSIT_MANAGER_ADDRESS", value = var.cngn_perp_srm_address },
    { name = "DEPOSIT_MIN_AMOUNT", value = var.deposit_min_amount },
    { name = "DEPOSIT_MAX_PER_HOUR", value = tostring(var.deposit_max_per_hour) },
    { name = "DEPOSIT_RECEIPT_TIMEOUT_MS", value = "30000" },
  ] : []
}
