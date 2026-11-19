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
  default     = "arn:aws:acm:us-east-1:957261948743:certificate/f77f24ce-52d8-4a19-a0ac-8a8c4487d18c"
}

# The image defaults below are THE DEPLOYED VALUES, kept current on every deploy. An apply that
# passes no -var flags must be a no-op; before they existed, every apply had to restate all three
# images by hand, and one forgotten flag rolled a service back to whatever the operator last
# remembered. Deploying = build-and-push, then edit the default here, plan, apply, commit.

variable "image_markets" {
  description = "ECR image URI for the Go binary (serves both api and matcher modes)."
  type        = string
  # 2026-10-28 19:54 UTC: main befe85e6 (#280: FUTURE_SERIES, listing MarginEngine v2's cNGN-30NOV26 closed).
  # markets td :46, matcher td :45. Rollback is 06d35e168f58 (td :45 / :44) with future_series = [], in one apply.
  # 2026-11-02: main 682cb2e (cNGN options: OPTION_SERIES, option order admission and fill margin checks), listing the ten
  # cNGN-30NOV26 strikes closed (option_series). Rollback is 13384daafef9 with option_series = [], in one apply.
  # 2026-11-02: main 67f82e3 (option listing states the size unit, 1,000 cNGN; option market id read from assetDetails word 2).
  # Applied 2026-11-02 02:33 UTC: markets td :53, matcher td :52. Rollback is 682cb2e0f9e2, in one apply.
  # 2026-11-03: main e5567ec (a linear future's size wording follows its amount scale: 1,000 cNGN a unit on cNGN-30NOV26).
  # Text only. Applied 2026-11-03 18:03 UTC: markets td :54, matcher td :53, migrate td :47. Rollback is 67f82e3e4b7b, in one apply.
  # 2026-11-03: main 7235bbc (the public API also served without /v1). Applied 2026-11-03 19:15 UTC: markets td :55, matcher td :54, migrate td :48,
  # with an 18-minute matcher outage and an RDS restart; rollout completed ~19:44. Rollback is e5567ec40f97, in one apply.
  # 2026-11-03: main b2951be (219ac60: no limit price backfill at boot). Applied 20:16 UTC: markets td :56, matcher td :55, migrate td :49, 0 failed tasks. Every older image scans active_orders at boot, so a rollback
  # to 7235bbc7f41b brings that back.
  # 2026-11-16: main 96974ae (0d8fc68: the matcher indexes the OnchainBook's Fill and TakeExecuted onto the series tape;
  # migration 000024 run first, migrate td :55). Rollback is 2fd91925220b, in one apply (000024 only adds, so the old
  # image runs on the migrated schema).
  # 2026-11-17: main df70d1e (the settlement verifier: each matcher fill checked on chain, voided only on proof it did
  # not settle; migration 000025 run first, migrate td :56). Rollback is 96974ae8e208, in one apply (000025 only adds).
  # 2026-11-17: main 6bb45f2 (9780841: the matcher indexes more than one OnchainBook, v2 beside v1; no migration).
  # Rollback is df70d1e726e1 with onchain_book_v2_address = "", in one apply.
  # 2026-11-18: main 0f52e76a (ONCHAIN_BOOK_CNGN: the matcher indexes the cNGN book). Rollback is 6bb45f2f367d, in one apply.
  # 2026-11-19: main 4ccb4698 (CNGN_SPOT_DELISTED / EURC_SPOT_DELISTED). Rollback is 0f52e76a3390, in one apply.
  # 2026-11-19: main adef99f1 (BookTakeModule: POST /book-takes and /book-depth on the API, POST /book-take on
  # execution). Rollback is 4ccb4698fec1, in one apply.
  # 2026-11-19: main 22fe88df (EURC-31DEC26 listed; /book-depth finds a series on any book market and reports
  # market_id). Rollback is adef99f11bb8, in one apply.
  # 2026-11-19: main f52cc949 (BookCustodian relay: POST /custodian on both, GET /custodian/accounts on the API;
  # CUSTODIAN_* env). Rollback is 22fe88df57b1 with custodian_address = "", in one apply.
  default = "957261948743.dkr.ecr.us-east-1.amazonaws.com/numo-exchange/markets:f52cc9490002"
}

variable "image_execution" {
  description = "ECR image URI for services/execution."
  type        = string
  # 2026-10-19: main a74cec2c (#237: the settlement canary sums wrapper backing across the SRM and the MarginEngine,
  # probes each account through its own manager, and watches 34 and 32), on top of 45144dff (#231).
  # 2026-11-17: main 917da47 (an HTTP 4xx on broadcast is a refusal, not a send: the 2026-11-16 phantom fill; sends via
  # SEND_RPC_URL, the keyed endpoint). Rollback is 3fe2553fb2d2, in one apply.
  # 2026-11-17: main d2c409c (the settlement canary's whitelist scan through SEND_RPC_URL: the public RPC refuses a
  # full-range getLogs, so every invariant check had failed to run). Rollback is 917da470fdd4, in one apply.
  # 2026-11-18: main c39ec112 (15fc964: the whitelist scan walks 49,999-block chunks from the SRM's deploy block and
  # resumes after a failed pass; publicnode, SEND_RPC_URL since the Alchemy outage, refuses wider). Rollback is
  # d2c409c4ef25, in one apply.
  # 2026-11-19: main adef99f1 (BookTakeModule: POST /book-takes and /book-depth on the API, POST /book-take on
  # execution). Rollback is c39ec1128990, in one apply.
  # 2026-11-19: main 22fe88df (EURC-31DEC26 listed; /book-depth finds a series on any book market and reports
  # market_id). Rollback is adef99f11bb8, in one apply.
  # 2026-11-19: main f52cc949 (BookCustodian relay: POST /custodian on both, GET /custodian/accounts on the API;
  # CUSTODIAN_* env). Rollback is 22fe88df57b1 with custodian_address = "", in one apply.
  default = "957261948743.dkr.ecr.us-east-1.amazonaws.com/numo-exchange/execution:f52cc9490002"
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
  # Unified cutover 2026-10-04: 0x12423B36 -> 0xDea96818, the perp TradeModule, so spot settles on
  # the perp stack. Applied from operator-local tfvars at the time and recorded here 2026-10-09.
  type    = string
  default = "0xDea968188598BA0E3F58A56C0fdfF338C74F699f"
}

variable "quote_asset_address" {
  # The asset `trade_module_address` settles the quote leg in, i.e. its quoteAsset(). The
  # markets service reads a buyer's balance of THIS contract before crossing a pair, so it
  # must be changed in the same commit as trade_module_address -- reading the wrong ledger
  # judges every buyer against balances the trade does not touch.
  #
  #   cash-quoted module    0x44813aD3...  ->  CashAsset            0x6B232A2155Bd0C9bf741dB4cf8E7e8A0176A6fc6
  #   wrapped-quote module  0x12423B36...  ->  WRAPPED_USDC_DELIV.  0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84
  #   perp module (unified) 0xDea96818...  ->  perp CashAsset       0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272
  #
  # Set at the 2026-09-10 cutover. This also turns the pre-trade funding check ON, which was
  # inert while it was empty -- watch for funding_check_enabled in the markets logs. The
  # matcher additionally reads TradeModule.quoteAsset() at startup and refuses to boot if this
  # disagrees with it, so a half-applied pair fails loudly instead of judging every buyer
  # against a ledger the trade does not touch.
  type    = string
  default = "0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272"
}

variable "cash_asset_address" {
  # The settlement-ledger CashAsset. Only the legacy fallback source of QUOTE_ASSET_ADDRESS;
  # prefer setting quote_asset_address explicitly.
  type    = string
  default = ""
}

variable "ws_allowed_origins" {
  description = "Origins allowed to open /ws. Empty means same-origin only, which breaks the browser app."
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

# The manager the spot market's accounts live under once spot runs on the perp stack (the unified
# account): the perp SRM. Empty while spot is on its own stack. Set together with
# trade_module_address = the perp TradeModule, quote_asset_address = the perp cash and
# cngn_spot_asset_address = the perp cNGN escrow: the unified cutover moves the four as one, and
# did so on 2026-10-04. Since 2026-10-14 (exchange #219) spot's accounts live under the MarginEngine
# (risk-core deployments/8453/MARGIN_ENGINE.json .manager), with deposit_manager_address. MarginEngine v2 step 4
# (risk-core docs/margin-engine-v2.md) moves both to v2, so spot and the v2 futures margin one account; v1 accounts
# keep trading spot until step 5 pins v1 close-only. v2's EURC cap is 0 until step 6, so no v2 account takes EURC
# before then.
variable "spot_margin_manager_address" {
  type    = string
  default = "0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950"
}

# Wrapped assets of a retired spot stack that withdrawals must keep paying out of after a cutover
# (the old wrapped USDC and spot cNGN escrow), so nobody is stranded on the old accounts.
variable "legacy_withdrawal_asset_addresses" {
  type    = list(string)
  default = ["0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84", "0x9d806fd040a719d27a8e5e77dc5ae0ed1e089493"]
}

variable "cngn_spot_asset_address" {
  # Losing this silently disables the only market. The boot guard turns that into a
  # crash; keeping it in Terraform keeps it from being lost in the first place.
  #
  # Since the unified cutover (2026-10-04) this is the perp cNGN escrow, the same contract as
  # cngn_perp_collateral_address. The spot stack's escrow 0x9D806fD0 is now a legacy withdrawal asset.
  type    = string
  default = "0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98"
}

# EURC-USDC spot: a WrappedERC20Asset escrow for Base EURC (0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42, 6
# decimals) under the MarginEngine as its market 2, on the same TradeModule and USDC cash as cNGN spot, and
# sharing spot_margin_manager_address. Empty lists nothing: markets-service and the matcher get no
# EURC_SPOT_ASSET_ADDRESS at all, EURC is neither depositable nor withdrawable, and every task definition
# renders exactly as it did before this variable existed (ecs.tf local.eurc_spot_env).
variable "eurc_spot_asset_address" {
  description = "The EURC-USDC spot market's EURC escrow (risk-core deployments/8453/EURC_SPOT.json .escrow once deployed). Empty: the market is not listed and EURC is not a deposit or withdrawal asset."
  type        = string
  # 2026-10-25: deployed at Base block 53068641 and configured as engine market 2 (#268, #269); applied as -var
  # the same day and written back here.
  default = "0xfD2AFbF4eF6E7a7f34A04D16Ff6da249Ca086cD9"
}

# cNGN-PERP's stack, on Base since 2026-09-30 (risk-core deployments/8453/CNGN_PERP_STACK.json,
# execution deployments/8453/CNGN_PERP_TRADE_MODULE.json). The TradeModule, CashAsset and SRM below
# are the venue's shared stack, not the perp's alone: spot and the future trade through that module
# and settle in that cash, USDC deposits default to it, and the settlement canary and both makers read
# it. Their defaults are the deployed contracts, committed so that an apply from a fresh clone can
# never plan them off; blanking them takes spot and the future down with the perp.
#
# The asset is the perp's listing alone. Empty since 2026-10-21: the perp is delisted (open interest
# zero, close-only since 2026-10-13), so /markets no longer lists it, cNGN-PERP and USDCcNGN-PERP
# are an unknown market, and perp state, funding, the perp margin check and the position indexer are
# off. markets-service accepts all four, the shared three without the asset, or none; it needs an
# image with that rule (exchange markets/delist-perp) before an apply that leaves this empty, or it
# refuses to boot. Relisting is setting it back to the PerpAsset, 0xC74EfC8B4808803dBCF439E76Fde076d56625b8E.
variable "cngn_perp_asset_address" {
  type    = string
  default = ""
}

variable "cngn_perp_trade_module_address" {
  type    = string
  default = "0xDea968188598BA0E3F58A56C0fdfF338C74F699f" # TradeModule (perp)
}

variable "cngn_perp_cash_address" {
  type    = string
  default = "0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272" # CashAsset (the perp's USDC cash)
}

variable "cngn_perp_srm_address" {
  type    = string
  default = "0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4" # StandardManager (perp SRM)
}

variable "deposit_manager_address" {
  description = "DEPOSIT_MANAGER_ADDRESS: the manager /deposits opens accounts under and deposits into. Empty keeps the perp SRM. The MarginEngine from 2026-10-14, MarginEngine v2 since step 4, with spot_margin_manager_address."
  type        = string
  default     = "0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950"
}

# The perp's cNGN collateral escrow (risk-core CNGN_PERP_COLLATERAL.json `escrow`). Set it only
# once the vault batch that whitelists it on the perp SRM has executed: markets-service then lists
# it under the perp's collateral_assets and reads each account's cNGN, and accepts withdrawals
# from it. Empty means cash-only margin. Whitelisted by vault batch 4 on 2026-10-03.
variable "cngn_perp_collateral_address" {
  type    = string
  default = "0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98"
}

# The cNGN future (USDC-cNGN-30NOV26), a FutureAsset series under the MarginEngine, deployed closed on
# 2026-10-13 and handed to the vault the same day (risk-core deployments/8453/MARGIN_ENGINE.json).
# markets-service and the matcher both read these: the api lists the series and refuses orders outside
# its fill band, the matcher crosses it only once the enable batch has opened it on chain. Until then
# the listing shows trading_open false and orders rest. All three or none (markets-service refuses a
# partial set at boot, and the set needs the perp stack above); "" for all three switches it off.
# Takes effect only on an image with the futures listing (exchange #183); older images ignore it.
# The perp close-only (markets-service CNGN_PERP_CLOSE_ONLY): every perp order is taken as reduce-only
# and the matcher holds every perp fill, resting orders included, to reducing each account's position.
# On since 2026-10-13, when the perp's market maker (#24) was stopped to fund the future's: no one
# should open a perp position with no maker to exit against. Exits stay open. Turn it off when the perp
# has a maker again.
#
# Turning it off is blocked until numofx/trading-app#131 is closed: since exchange #227 a perp read
# failure on /positions is a 200 with the perp keys absent, which the trading app shows as a flat
# perp. Harmless while no one can hold a perp; wrong for real holders once it reopens. Remove this
# validation when #131 is merged.
variable "cngn_perp_close_only" {
  type    = bool
  default = true

  validation {
    condition     = var.cngn_perp_close_only
    error_message = "The perp cannot leave close-only until numofx/trading-app#131 is fixed: the trading app would show perp holders as flat whenever /positions cannot read the perp. See the comment on this variable."
  }
}

# MarginEngine v1's USDC-cNGN-30NOV26 (FutureAsset 0xDCFa…1Bc19 under 0xA19E…0758), DELISTED 2026-11-19 (owner's
# decision): flat since 2026-10-31 (totalPosition 0, cap 0), no maker since that day, nothing to settle. All three empty
# lists nothing (markets-service: "all three or none"). v1's engine stays watched by the canary (ecs.tf
# local.margin_engine_v1). Relisting is these three defaults and close_only back.
variable "cngn_future_asset_address" {
  type    = string
  default = ""
}

variable "cngn_future_expiry" {
  description = "The series' expiry (its subId), unix seconds. Was 1796047200 (2026-11-30 14:00 UTC) until delisted."
  type        = string
  default     = ""
}

variable "cngn_future_manager_address" {
  type    = string
  default = ""
}

# MarginEngine v2 step 4 (risk-core docs/margin-engine-v2.md): v1's series above is listed close-only
# once v2's is open. Every order on it is then taken as reduce-only. Absent from the task definitions
# while false, so adding the variable changes nothing deployed.
variable "cngn_future_close_only" {
  type    = bool
  default = false # markets-service refuses it without the series
}

# Further futures series, listed beside the cngn_future_* one (markets-service FUTURE_SERIES, README
# "More series"): MarginEngine v2's <BASE>-<DDMONYY>. Keyed by (asset_address, expiry); two series may
# share an expiry. Empty lists nothing more, and leaves FUTURE_SERIES out of the task definitions.
# v2's cNGN-30NOV26 listed 2026-10-28 while v2 is closed (trading_open false until the enable batch): its forward
# publisher reads its book. Order unit 1,000 cNGN. Since 2026-10-31 the v2 makers (#39, #40) quote both series, the
# app shows them (trading-app 59a5454), and the settlement canary watches their engine (local.canary_other_managers).
variable "future_series" {
  type = list(object({
    asset_address   = string
    expiry          = number
    manager_address = string
    kind            = string # "inverse" (v1) or "linear" (v2)
    base_asset      = string
    contract_size   = string # whole units a contract: FutureAsset.contractSize() / 1e18
    amount_scale    = optional(string)
    symbol          = optional(string)
    close_only      = optional(bool, false)
    taker_fee_bps   = number # required: bps of the notional; no default, so a new series states its fee
  }))
  default = [{
    asset_address   = "0xcACEe66ad41fD1472a47D7D5Fe372FFbFac9AA75"
    expiry          = 1796047200
    manager_address = "0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950"
    kind            = "linear"
    base_asset      = "cNGN"
    contract_size   = "1000000"
    amount_scale    = "1000000000000000" # 1,000 cNGN: 1e18 per 1,000,000 cNGN contract
    taker_fee_bps   = 15                 # 2026-10-31, from 25
    }, {
    # EURC-30NOV26 v3 (risk-core EURC_FUTURE_V3.json, deployed 2026-11-15), replacing the retired v2 series
    # 0x6Ff7…7744 (1796054400, no open interest, off Matching): USDC per EURC, 1,000 EURC a contract, settled from Data
    # Streams. Opened 2026-11-15 by the owner before the mainnet canary settled (spec A1.4): the canary finishes
    # unattended, with the 15 days to Nov 30 to fix anything it finds.
    asset_address   = "0xC350243c1d07Ff598770ECe12323799D2EFbB227"
    expiry          = 1796050800
    manager_address = "0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950"
    kind            = "linear"
    base_asset      = "EURC"
    contract_size   = "1000"
    amount_scale    = "1000000000000000" # 1 EURC: 1e18 per 1,000 EURC contract
    taker_fee_bps   = 5                  # as v2's: EURC-USDC spot's 5
    }, {
    # EURC-31DEC26 (listing run-sheet L6): listed on the v3 future 2026-11-18 (L4), expiry Thu 2026-12-31 15:00 UTC,
    # last trade 14:30. Its book is market 2 on the EURC v2 OnchainBook (next-series run-sheet).
    asset_address   = "0xC350243c1d07Ff598770ECe12323799D2EFbB227"
    expiry          = 1798729200
    manager_address = "0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950"
    kind            = "linear"
    base_asset      = "EURC"
    contract_size   = "1000"
    amount_scale    = "1000000000000000" # 1 EURC: 1e18 per 1,000 EURC contract
    taker_fee_bps   = 5
  }]

  validation {
    condition     = alltrue([for s in var.future_series : s.taker_fee_bps >= 0 && s.taker_fee_bps <= 100 && floor(s.taker_fee_bps) == s.taker_fee_bps])
    error_message = "Each future_series entry's taker_fee_bps is a whole number of bps from 0 to 100 (markets-service refuses anything else)."
  }

  validation {
    condition     = alltrue([for s in var.future_series : contains(["inverse", "linear"], s.kind)])
    error_message = "Each future_series entry's kind is \"inverse\" (MarginEngine v1) or \"linear\" (v2)."
  }
}

# cNGN options (markets-service OPTION_SERIES, internal/config/option_series.go), one entry per OptionAsset expiry: every
# strike is listed as a call and a put, priced as the premium in USDC per base, the fee in bps of the premium. Addresses
# from risk-core CNGN_OPTIONS_V2.json once deployed. Empty lists none and leaves OPTION_SERIES out of the task
# definitions. markets-service refuses a strike off the 1e-8 grid, a duplicate, or a last_trade_time not before expiry.
variable "option_series" {
  type = list(object({
    asset_address    = string
    manager_address  = string
    vol_feed_address = string
    base_asset       = string
    expiry           = number
    last_trade_time  = optional(number) # default: an hour before expiry
    strikes          = list(string)     # decimal USDC per base, e.g. "0.00072"
    amount_scale     = string           # 1e21: desired_amount 1 is 1,000 of the base
    taker_fee_bps    = number           # required: bps of the premium
  }))
  # cNGN options at the cNGN-30NOV26 expiry (risk-core CNGN_OPTIONS_V2.json, deployed and set up 2026-11-02, closed until
  # cngn-options-enable). Strikes chosen 2026-11-02 around the forward ~0.000721: -14%, -7%, at, +7%, +14%, each a call and
  # a put (10 markets). Taker fee 15 bps of the premium, the user's choice (about $0.05 on a 1M cNGN ATM option at ~$32).
  # Orders sized in thousands of cNGN (amount_scale 1e21), as the cNGN future's order unit.
  # Delisted 2026-11-19 (total position 0 under v2, the maker #44 stopped and emptied): the cNGN-30NOV26 options were
  # OptionAsset 0xA6a05dC25127CecbC048C7e6CBE35e1c8e503821 under v2, vol feed 0xf2dB01CF…C5E0, expiry 1796047200, strikes
  # 0.00062/0.00067/0.00072/0.00077/0.00082 (call and put), amount_scale 1e21, taker fee 15 bps of the premium.
  default = []

  validation {
    condition     = alltrue([for s in var.option_series : s.taker_fee_bps >= 0 && s.taker_fee_bps <= 1000 && floor(s.taker_fee_bps) == s.taker_fee_bps])
    error_message = "Each option_series entry's taker_fee_bps is a whole number of bps of the premium from 0 to 1000 (markets-service refuses anything else)."
  }

  validation {
    condition     = alltrue([for s in var.option_series : length(s.strikes) > 0])
    error_message = "Each option_series entry lists at least one strike."
  }
}

# The index-lag gate (markets-service api/index_lag.go). The publisher reports every spot sample to
# the api; with the gate on, a new perp order is refused while that sample is more than
# index_lag_max_bps from the on-chain index, or while no fresh sample exists. On in production since
# 2026-10-04 (markets-service task definition 28 onward); set false to watch the reports on
# /markets (perp.index_lag) without refusing anything.
variable "index_lag_gate" {
  type    = bool
  default = true
}

variable "index_lag_max_bps" {
  type    = number
  default = 100
}

# How old the publisher's latest good spot sample may be before the venue counts itself blind and
# (with the gate on) refuses new perp orders. A Go duration. Sized to the 5-minute TWAP window.
variable "index_status_max_age" {
  type    = string
  default = "300s"
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
  description = "The SPOT market maker's mm-bot image, tagged by git SHA. Built from numofx/market-maker."
  type        = string
  # What market-maker-spot runs. It was briefly shared with the perp maker, so a perp-only image bump (#160, for
  # MM_INVENTORY_SKEW_FULL_AT) silently became a planned spot rollout; each maker now has its own pin.
  # 2026-10-21: d3a78aa3a2df, market-maker #42 (SpotMarket names only the cNGN spot market; with EURC-USDC listed
  # the old image could pick it at startup and refuse to run). Everything else in it already runs as the future
  # maker's 91ad6ac7462e. EURC rollout step 0.
  # 2026-11-04: d3a78aa3a2df plus the /v1 path change and the fee-schedule fix only (market-maker tag deploy/mm-spot-fee-fix), so no strategy change.
  # 2026-11-13: 15f4c5f401de = deploy/mm-spot-rpc-count, the previous image plus only market-maker aa70ebe9 (rpc_calls
  # logged per minute by host, method and status), so no strategy change.
  default = "957261948743.dkr.ecr.us-east-1.amazonaws.com/numo-exchange/market-maker:15f4c5f401de"
}

variable "image_market_maker_perp" {
  description = "The PERP market maker's mm-bot image, tagged by git SHA. Same repository as image_market_maker, pinned separately."
  type        = string
  # 2026-10-10: MM_INVENTORY_SKEW_FULL_AT (market-maker #33, exchange #160).
  default = "957261948743.dkr.ecr.us-east-1.amazonaws.com/numo-exchange/market-maker:e1ef066eb680"
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

# The spot market-maker's trading account (its MM_SUBACCOUNT_ID and MM_RECIPIENT_ID): #34 under the
# MarginEngine since 2026-10-14 (inventory moved from #26 under the perp SRM, exchange #219). #26, and
# #15 on the retired spot stack, are no longer the maker's.
# The cNGN-USDC maker's account: #42 under MarginEngine v2 since 2026-10-31 (v2 step 5 prep; #34 under v1 emptied).
variable "mm_subaccount_id" {
  type    = string
  default = "42"
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

variable "perp_guardian_kms_enabled" {
  description = <<-EOT
    Creates the USDCcNGN-PERP guardian's KMS signing key (alias/<name>-perp-guardian). Defaults to
    true, like the other signing keys: a plan that forgets the flag must not propose deleting a key
    whose address is the perp's guardian (prevent_destroy would refuse anyway).
  EOT
  type        = bool
  default     = true
}


variable "forward_signer_kms_enabled" {
  description = <<-EOT
    Create the KMS signing key for the cNGN future's forward publisher (numo-future-feeds on the
    ops box) and grant the ops box's role Sign on it.

    Its own key, deliberately NOT the perp index signer: FutureAsset bands every mark against the
    index, which only bounds a bad forward if someone else signs the index. Held in KMS rather than
    SSM so the private key never reaches the box the index signer lives on.

    Creating the key authorises nothing: its address must be added as the forward feed's signer
    (the deploy script's FORWARD_SIGNER). Created 2026-10-13 (alias/numo-exchange-forward-signer,
    address 0xd65FBC1D6ee445DF9A1393a93356C1c4CaC43650) and defaulted true, as for the executor and
    rebalance keys: a plan that resolves it to false would propose deleting the forward signer.
  EOT
  type        = bool
  default     = true
}

variable "vol_signer_kms_enabled" {
  description = <<-EOT
    Create the KMS signing key for the cNGN options' vol publisher (numo-vol-feeds on the ops box) and grant the ops
    box's role Sign on it.

    Its own key, NOT the index's or the forward's: the deploy script refuses a vol signer that signs either, and the
    publisher refuses a raw key on mainnet. Creating the key authorises nothing: its address is the deploy script's
    VOL_SIGNER, added to the vol feed at deploy. Created 2026-11-01 (alias/numo-exchange-vol-signer, key
    f8207956-f587-4b40-a0ab-1430e5dd9a47, address 0x30b9c910777a0B08fCfD645bca4121bDDC12fbf5) for the cNGN options
    deploy. Keep it true: a plan that resolves it to false would propose deleting a feed signer (prevent_destroy
    refuses that).
  EOT
  type        = bool
  default     = true
}

variable "ops_box_mm_key_grant" {
  description = <<-EOT
    Let the ops box read /numo/exchange/mm_private_key, and nothing else under /numo/exchange/ (see
    ops-box.tf). Only for the length of one task, applied with -var and removed by the next apply from
    main; never set true here. Last used: the futures market maker's MarginEngine account.
  EOT
  type        = bool
  default     = false
}

# risk-core's OnchainBook (ONCHAIN_BOOK.json, from deploy-onchain-book.s.sol) and its deploy block. Set both once it is
# deployed: the matcher then indexes its Fill and TakeExecuted events onto the series' tape from that block. Empty
# leaves both out of the matcher's task definition.
variable "onchain_book_address" {
  type = string
  # Deployed 2026-11-16 (risk-core deployments/8453/ONCHAIN_BOOK.json), enabled 22:27 UTC.
  default = "0x8Fc63DcB3a173aAF5d2de0F42648D908A519d456"
  validation {
    condition     = var.onchain_book_address == "" || can(regex("^0x[0-9a-fA-F]{40}$", var.onchain_book_address))
    error_message = "onchain_book_address must be an address or empty."
  }
}

# Required with the address (a precondition on the matcher's task definition: variable validations cannot read
# another variable before Terraform 1.9).
variable "onchain_book_start_block" {
  type = number
  # The book's create transaction (0xa3bc740a…2baa).
  default = 58358413
}

# The v2 OnchainBook (risk-core ONCHAIN_BOOK_V2.json: quote, self-priced splines; spec C4) and its deployBlock, indexed
# beside v1. Empty: not indexed, and the matcher's task definition does not change.
variable "onchain_book_v2_address" {
  type = string
  # Deployed 2026-11-17 closed on EURC-30NOV26 (risk-core deployments/8453/ONCHAIN_BOOK_V2.json); setup batch landed 13:44 UTC.
  default = "0x83C5741a24d57189379E1215F7A22d9f048E89d5"
  validation {
    condition     = var.onchain_book_v2_address == "" || can(regex("^0x[0-9a-fA-F]{40}$", var.onchain_book_v2_address))
    error_message = "onchain_book_v2_address must be an address or empty."
  }
}

variable "onchain_book_v2_start_block" {
  type = number
  # The book's create transaction (0x769e0c25…, block 58,656,423). ONCHAIN_BOOK_V2.json's deployBlock (58,656,411) is
  # the block the script ran at, a lower bound.
  default = 58656423
}

variable "onchain_book_cngn_address" {
  type = string
  # The adapter-less cNGN book, deployed 2026-11-18 22:48 UTC on cNGN-30NOV26 (risk-core ONCHAIN_BOOK_CNGN.json); setup
  # landed 22:53, market disabled until the enable batch. Needs markets with ONCHAIN_BOOK_CNGN (2026-11-18).
  default = "0x5a35f149005Ce74b874F7Cf07CC2618BFA4F8Bd4"
  validation {
    condition     = var.onchain_book_cngn_address == "" || can(regex("^0x[0-9a-fA-F]{40}$", var.onchain_book_cngn_address))
    error_message = "onchain_book_cngn_address must be an address or empty."
  }
}

variable "onchain_book_cngn_start_block" {
  type = number
  # The book's create transaction (0x061036ba58…, block 59,258,624).
  default = 59258624
}

# The OnchainBook makers' RPC (market-maker-book, -book-v2, -book-cngn). Not rpc_fallback_url: publicnode answers
# eth_getTransactionReceipt for a not-yet-mined tx with HTTP 403 "Archive requests require a personal token" where a
# node answers null, and the bot took each as a failed cycle and resent its update every 5 s poll (2026-11-19: the cNGN
# maker 120 sends in 10 minutes, ~10x its cadence). mainnet.base.org answers null. Public, so plain env, not a secret.
variable "book_maker_rpc_url" {
  type    = string
  default = "https://mainnet.base.org"
}

# Spot delisted 2026-11-19 (owner's decision, after both makers' inventory went to 0x8f49…1B7a): markets-service
# CNGN_SPOT_DELISTED / EURC_SPOT_DELISTED (needs markets image with them). The asset addresses above stay set: they
# are also the cNGN and EURC deposit and withdrawal assets, and futures accounts hold both as collateral.
variable "cngn_spot_delisted" {
  type    = bool
  default = true
}

variable "eurc_spot_delisted" {
  type    = bool
  default = true
}

# BookTakeModule (contracts/execution/deployments/8453/BOOK_TAKE_MODULE.json): signed takes on the OnchainBooks for
# accounts Matching holds, the executor paying gas. Empty leaves POST /book-takes and /book-take off (503). Inert on
# chain until the vault's batch (propose_book_take_module.py) has Matching allow it.
variable "book_take_module_address" {
  type    = string
  default = "0x1D1FcAa8C1677dF51dda4F26bc391B91b98dEBE3"
}

# BookCustodian (contracts/risk-core/deployments/8453/BOOK_CUSTODIAN.json, docs/book-custodian-spec.md): app users'
# accounts held so the OnchainBooks can act on them; POST /custodian relays its calls, GET /custodian/accounts finds a
# wallet's. Empty leaves both off (503). Its deposit and withdrawal assets are cash and the EURC asset, as allowed on
# chain at deploy; the cNGN asset is not whitelisted on engine v2.
variable "custodian_address" {
  type    = string
  default = "0xD8EBF2216Fd4ECA79272E76ad22131592EA0dfd6"
}

variable "custodian_deploy_block" {
  type    = number
  default = 59581388
}
