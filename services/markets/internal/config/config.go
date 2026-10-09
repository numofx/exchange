package config

import (
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	AppEnv              string
	APIAddr             string
	DatabaseURL         string
	MatcherPollInterval time.Duration
	// MatcherHealthAddr is where the matcher serves its own /healthz (MATCHER_HEALTH_ADDR, default
	// ":8082"); empty disables it.
	MatcherHealthAddr      string
	ChainRPCURL            string
	ChainID                string
	MatchingAddress        string
	EnforceMatchingCustody bool
	// EnforceOrderSignatures rejects an order whose signature does not authorize its action.
	// Off by default: the digest must match ActionVerifier exactly, and a mismatch would reject
	// every order, so turn it on only after the mismatch logs show a clean run against real
	// traffic. Signatures are checked and logged either way.
	EnforceOrderSignatures bool
	// EnforceCancelSignatures rejects a cancel whose signature does not authorize it. Off by
	// default and rolled out the same way as EnforceOrderSignatures: the signature is checked and
	// logged either way, and enforcement is flipped on only once the logs show real clients are
	// signing cancels cleanly. Until a client sends a signature, an unsigned cancel is simply
	// unverifiable and — with enforcement off — still allowed, exactly as it is today.
	EnforceCancelSignatures bool
	TradeModuleAddress      string
	ExecutorURL             string
	ExecutorManagerData     string
	// ExecutorTimeout bounds the whole HTTP exchange with execution-service. It must
	// exceed that service's RECEIPT_TIMEOUT_MS whenever WAIT_FOR_RECEIPT is on: if the
	// matcher gives up first, the transaction is still in flight, the pair is released,
	// and the retry simulates against a nonce whose fill has not landed yet -- so it
	// passes, and a second verifyAndMatch goes out for a fill already broadcast.
	ExecutorTimeout time.Duration
	// WithdrawalModuleAddress is the WithdrawalModule every signed withdrawal must target. With
	// ExecutorWithdrawURL unset or this unset, POST /v1/withdrawals answers 503.
	WithdrawalModuleAddress string
	// WithdrawalAssetAddresses are the wrapped assets a withdrawal may pay out of, lowercased:
	// WITHDRAWAL_ASSET_ADDRESSES, or by default the quote asset and the cNGN spot asset.
	WithdrawalAssetAddresses []string
	// ExecutorWithdrawURL is execution-service's POST /withdraw. Unlike ExecutorURL it is read by
	// the API process, not the matcher.
	ExecutorWithdrawURL string
	// ExecutorWithdrawTimeout bounds the forward to execution-service, which waits for the receipt.
	// It must exceed that service's WITHDRAWAL_RECEIPT_TIMEOUT_MS, or the API reports an unknown
	// outcome for a withdrawal that was about to land.
	ExecutorWithdrawTimeout time.Duration
	// Signed deposits (POST /v1/deposits), through the deployed DepositModule with the venue paying gas. Off unless
	// DEPOSITS_ENABLED; when on and anything below is missing, the endpoint answers 503 rather than half-check.
	DepositsEnabled bool
	// DepositModuleAddress is the DepositModule every signed deposit must target.
	DepositModuleAddress string
	// DepositAssetAddresses are the wrapped assets a deposit may pay into, lowercased: DEPOSIT_ASSET_ADDRESSES, or by
	// default the perp's CashAsset alone. The chain also accepts the cNGN escrow; this allowlist is what refuses it.
	DepositAssetAddresses []string
	// DepositManagerAddress is the only manager a new account may be opened under: DEPOSIT_MANAGER_ADDRESS, or by
	// default the perp SRM.
	DepositManagerAddress string
	// DepositMinAmount is the smallest deposit, in 6-decimal USDC base units (DEPOSIT_MIN_AMOUNT, default 10 USDC).
	DepositMinAmount *big.Int
	// DepositsPerOwnerPerMinute caps how often one owner can make the venue simulate, and pay gas for, a deposit.
	DepositsPerOwnerPerMinute int
	// DepositsPerOwnerPerHour caps the deposits one owner can have the venue submit in a rolling hour. Without it one
	// wallet at the per-minute rate could spend the executor's whole hourly budget and lock everyone else out.
	DepositsPerOwnerPerHour int
	// ExecutorDepositURL is execution-service's POST /deposit.
	ExecutorDepositURL string
	// ExecutorDepositTimeout must exceed execution-service's DEPOSIT_RECEIPT_TIMEOUT_MS.
	ExecutorDepositTimeout time.Duration
	// AlertWebhookURL is the ops webhook (ALERT_WEBHOOK_URL) the matcher posts settlement failures to. Empty: off.
	AlertWebhookURL     string
	ExpectedOrderOwner  string
	ExpectedOrderSigner string
	DeribitBaseURL      string
	DeribitWSURL        string

	CNGNSpotAssetAddress string
	// SpotMarginManagerAddress is the manager the spot market's accounts live under when spot runs
	// on the perp stack (the unified account): set to the perp SRM so the venue refuses spot orders
	// while that SRM is paused and presents the manager to clients. Empty: spot's own stack.
	SpotMarginManagerAddress string

	// cNGN-PERP, on its own stack (risk-core CNGN_PERP_STACK.json and execution
	// CNGN_PERP_TRADE_MODULE.json). All four or none: the perp settles through its own TradeModule,
	// in its own CashAsset, margined by its own SRM, and a partial set would route perp orders
	// through the spot module or check them against the wrong manager.
	CNGNPerpAssetAddress       string
	CNGNPerpTradeModuleAddress string
	CNGNPerpCashAddress        string
	CNGNPerpSRMAddress         string
	// CNGNPerpCollateralAddress is the perp stack's own cNGN escrow (risk-core
	// CNGN_PERP_COLLATERAL.json `escrow`), once the vault has whitelisted it as a base asset on the
	// perp SRM. Optional: unset, the perp is margined in its cash only and /v1/positions reports no
	// collateral. It is also a withdrawable asset by default.
	CNGNPerpCollateralAddress string
	// The index-lag gate (api/index_lag.go). IndexStatusToken authenticates the publisher's spot
	// reports on POST /v1/internal/index-status; empty disables the endpoint and the gate. With
	// IndexLagGate on, a new perp order is refused while the latest good spot sample is more than
	// IndexLagMaxBps from the on-chain index, or when no sample newer than IndexStatusMaxAge exists.
	// The publisher samples once a minute and refuses a sample when fewer than three sources answer,
	// so the max age is the TWAP window (5 minutes), not a couple of samples: two refused samples in a
	// row happened within an hour of going live and must not blind the venue.
	IndexStatusToken  string
	IndexLagGate      bool
	IndexLagMaxBps    int
	IndexStatusMaxAge time.Duration
	// CashAssetAddress is the CashAsset contract. Kept as the legacy source of QuoteAssetAddress
	// so an existing deployment that only sets CASH_ASSET_ADDRESS keeps working unchanged.
	CashAssetAddress string
	// QuoteAssetAddress is the asset the TradeModule settles the quote leg in, i.e. its
	// `quoteAsset()`. Required to check that a buyer can fund notional + fee before a pair is
	// crossed: the funding check reads SubAccounts.getBalance(account, quoteAsset, 0), and reading
	// the WRONG asset is worse than reading none -- every buyer looks funded or unfunded against a
	// ledger the trade does not touch.
	//
	// This is a separate variable from CASH_ASSET_ADDRESS because the two stop being the same
	// contract the moment the USDC leg moves to the wrapped USDC asset. Defaults to
	// CASH_ASSET_ADDRESS when QUOTE_ASSET_ADDRESS is unset, which is what every deployment before
	// that migration wants.
	QuoteAssetAddress            string
	EnforceFundingCheck          bool
	EnforceActionDataInvariants  bool
	CancelProtectedOrderPrefixes []string

	// Real-time event pipeline (internal/events). See docs/realtime-api-design.md.
	EventsPruneHorizon      time.Duration // max age of a market_events row (= max reconnect-replay window)
	EventsPruneInterval     time.Duration // how often the prune job runs
	EventsReconcileInterval time.Duration // backstop drain cadence in case a NOTIFY is missed
	EventsSubBuffer         int           // per-subscriber channel depth before a slow consumer is dropped

	// Retention for terminal rows in active_orders (internal/orders). Market-maker
	// requoting leaves a cancelled row per replaced quote — thousands per day — and
	// without this the table grows without bound. 'filled' orders are never pruned.
	OrdersPruneHorizon  time.Duration // max age of a cancelled/expired order row
	OrdersPruneInterval time.Duration // how often the prune job runs; 0 disables it
	OrdersPruneBatch    int           // rows deleted per statement, to bound WAL per transaction

	// WebSocket auth (internal/wsauth) for the private 'orders' channel.
	WSAuthDomain     string        // SIWE domain bound into the signed message
	WSAuthMaxTTL     time.Duration // max validity window of a single signed auth frame (replay bound)
	WSAllowedOrigins []string      // browser Origin allowlist; empty = same-origin only

	// Max validity window of a GET /v1/orders auth frame (internal/wsauth, OrderHistoryStatement).
	// Longer than WSAuthMaxTTL because every history request is verified, where a socket verifies
	// once per connection; the frame only reads the signer's own orders.
	OrderHistoryAuthMaxTTL time.Duration
}

func Load() (Config, error) {
	cfg := Config{
		AppEnv:                  getenvDefault("APP_ENV", "dev"),
		APIAddr:                 getenvDefault("API_ADDR", ":8080"),
		DatabaseURL:             os.Getenv("DATABASE_URL"),
		ChainRPCURL:             getenvDefault("CHAIN_RPC_URL", os.Getenv("RPC_URL")),
		MatcherHealthAddr:       getenvDefault("MATCHER_HEALTH_ADDR", ":8082"),
		ChainID:                 os.Getenv("CHAIN_ID"),
		MatchingAddress:         os.Getenv("MATCHING_ADDRESS"),
		EnforceMatchingCustody:  getenvBool("ENFORCE_MATCHING_CUSTODY", true),
		EnforceOrderSignatures:  getenvBool("ENFORCE_ORDER_SIGNATURES", false),
		EnforceCancelSignatures: getenvBool("ENFORCE_CANCEL_SIGNATURES", false),
		TradeModuleAddress:      os.Getenv("TRADE_MODULE_ADDRESS"),
		ExecutorURL:             os.Getenv("EXECUTOR_URL"),
		WithdrawalModuleAddress: strings.ToLower(strings.TrimSpace(os.Getenv("WITHDRAWAL_MODULE_ADDRESS"))),
		ExecutorWithdrawURL:     strings.TrimSpace(os.Getenv("EXECUTOR_WITHDRAW_URL")),
		ExecutorManagerData:     "0x",
		ExpectedOrderOwner:      os.Getenv("EXPECTED_ORDER_OWNER"),
		ExpectedOrderSigner:     os.Getenv("EXPECTED_ORDER_SIGNER"),
		DeribitBaseURL:          getenvDefault("DERIBIT_BASE_URL", "https://test.deribit.com/api/v2"),
		DeribitWSURL:            getenvDefault("DERIBIT_WS_URL", "wss://test.deribit.com/ws/api/v2"),

		CNGNSpotAssetAddress:         strings.ToLower(strings.TrimSpace(os.Getenv("CNGN_SPOT_ASSET_ADDRESS"))),
		SpotMarginManagerAddress:     strings.ToLower(strings.TrimSpace(os.Getenv("SPOT_MARGIN_MANAGER_ADDRESS"))),
		CNGNPerpAssetAddress:         strings.ToLower(strings.TrimSpace(os.Getenv("CNGN_PERP_ASSET_ADDRESS"))),
		CNGNPerpTradeModuleAddress:   strings.ToLower(strings.TrimSpace(os.Getenv("CNGN_PERP_TRADE_MODULE_ADDRESS"))),
		CNGNPerpCashAddress:          strings.ToLower(strings.TrimSpace(os.Getenv("CNGN_PERP_CASH_ADDRESS"))),
		CNGNPerpSRMAddress:           strings.ToLower(strings.TrimSpace(os.Getenv("CNGN_PERP_SRM_ADDRESS"))),
		CNGNPerpCollateralAddress:    strings.ToLower(strings.TrimSpace(os.Getenv("CNGN_PERP_COLLATERAL_ADDRESS"))),
		IndexStatusToken:             strings.TrimSpace(os.Getenv("INDEX_STATUS_TOKEN")),
		IndexLagGate:                 getenvBool("INDEX_LAG_GATE", false),
		IndexLagMaxBps:               getenvIntDefault("INDEX_LAG_MAX_BPS", 100),
		IndexStatusMaxAge:            getenvDurationDefault("INDEX_STATUS_MAX_AGE", 300*time.Second),
		CashAssetAddress:             strings.ToLower(strings.TrimSpace(os.Getenv("CASH_ASSET_ADDRESS"))),
		QuoteAssetAddress:            strings.ToLower(strings.TrimSpace(os.Getenv("QUOTE_ASSET_ADDRESS"))),
		EnforceFundingCheck:          getenvBool("ENFORCE_FUNDING_CHECK", true),
		EnforceActionDataInvariants:  getenvBool("ENFORCE_ACTION_DATA_INVARIANTS", true),
		CancelProtectedOrderPrefixes: getenvCSV("CANCEL_PROTECTED_ORDER_ID_PREFIXES", "validation:,smoke:,manual:"),
	}

	managerData, err := loadExecutorManagerData()
	if err != nil {
		return Config{}, err
	}
	cfg.ExecutorManagerData = managerData

	if cfg.DatabaseURL == "" {
		return Config{}, fmt.Errorf("DATABASE_URL is required")
	}

	pollInterval, err := time.ParseDuration(getenvDefault("MATCHER_POLL_INTERVAL", "250ms"))
	if err != nil {
		return Config{}, fmt.Errorf("parse MATCHER_POLL_INTERVAL: %w", err)
	}
	cfg.MatcherPollInterval = pollInterval

	cfg.ExecutorTimeout = getenvDurationDefault("EXECUTOR_TIMEOUT", 5*time.Second)
	cfg.ExecutorWithdrawTimeout = getenvDurationDefault("EXECUTOR_WITHDRAW_TIMEOUT", 45*time.Second)
	cfg.WithdrawalAssetAddresses = withdrawalAssets(cfg)

	cfg.AlertWebhookURL = strings.TrimSpace(os.Getenv("ALERT_WEBHOOK_URL"))
	cfg.DepositsEnabled = getenvBool("DEPOSITS_ENABLED", false)
	cfg.DepositModuleAddress = strings.ToLower(strings.TrimSpace(os.Getenv("DEPOSIT_MODULE_ADDRESS")))
	cfg.DepositAssetAddresses = getenvCSV("DEPOSIT_ASSET_ADDRESSES", cfg.CNGNPerpCashAddress)
	cfg.DepositManagerAddress = strings.ToLower(strings.TrimSpace(getenvDefault("DEPOSIT_MANAGER_ADDRESS", cfg.CNGNPerpSRMAddress)))
	cfg.ExecutorDepositURL = strings.TrimSpace(os.Getenv("EXECUTOR_DEPOSIT_URL"))
	cfg.ExecutorDepositTimeout = getenvDurationDefault("EXECUTOR_DEPOSIT_TIMEOUT", 45*time.Second)
	cfg.DepositsPerOwnerPerMinute = getenvIntDefault("DEPOSITS_PER_OWNER_PER_MINUTE", 3)
	cfg.DepositsPerOwnerPerHour = getenvIntDefault("DEPOSITS_PER_OWNER_PER_HOUR", 6)
	minDeposit, ok := new(big.Int).SetString(getenvDefault("DEPOSIT_MIN_AMOUNT", "10000000"), 10)
	if !ok || minDeposit.Sign() <= 0 {
		return Config{}, fmt.Errorf("DEPOSIT_MIN_AMOUNT must be a positive integer of 6-decimal USDC base units")
	}
	cfg.DepositMinAmount = minDeposit

	cfg.EventsPruneHorizon = getenvDurationDefault("EVENTS_PRUNE_HORIZON", 2*time.Hour)
	cfg.EventsPruneInterval = getenvDurationDefault("EVENTS_PRUNE_INTERVAL", 5*time.Minute)
	cfg.EventsReconcileInterval = getenvDurationDefault("EVENTS_RECONCILE_INTERVAL", 5*time.Second)
	cfg.EventsSubBuffer = getenvIntDefault("EVENTS_SUB_BUFFER", 256)

	cfg.OrdersPruneHorizon = getenvDurationDefault("ORDERS_PRUNE_HORIZON", 30*24*time.Hour)
	cfg.OrdersPruneInterval = getenvDurationDefault("ORDERS_PRUNE_INTERVAL", time.Hour)
	cfg.OrdersPruneBatch = getenvIntDefault("ORDERS_PRUNE_BATCH", 5000)

	cfg.WSAuthDomain = getenvDefault("WS_AUTH_DOMAIN", "markets.numo.xyz")
	cfg.WSAuthMaxTTL = getenvDurationDefault("WS_AUTH_MAX_TTL", 5*time.Minute)
	cfg.OrderHistoryAuthMaxTTL = getenvDurationDefault("ORDER_HISTORY_AUTH_MAX_TTL", 24*time.Hour)
	cfg.WSAllowedOrigins = getenvCSV("WS_ALLOWED_ORIGINS", "")

	if err := cfg.validateFundingCheck(); err != nil {
		return Config{}, err
	}
	if err := cfg.validateTradeModule(); err != nil {
		return Config{}, err
	}
	if err := cfg.validatePerpStack(); err != nil {
		return Config{}, err
	}

	return cfg, nil
}

// IsProduction reports whether this process is running against real funds. Anything that is not
// explicitly a development or test environment is treated as production, so a typo'd APP_ENV
// fails safe rather than quietly disabling guards.
func (c Config) IsProduction() bool {
	switch strings.ToLower(strings.TrimSpace(c.AppEnv)) {
	case "", "dev", "development", "local", "test", "ci":
		return false
	default:
		return true
	}
}

// validateFundingCheck refuses to start in production with the funding check silently inert.
//
// The check reads the buyer's cash and requires it to cover notional + fee before a pair is
// crossed. Without CASH_ASSET_ADDRESS it no-ops: matching still works, but underfunded buys are
// discovered only when the settlement transaction reverts, after the book has moved. That is the
// behaviour the check exists to remove, and it is invisible from the outside -- nothing errors,
// nothing is logged per-match, trades simply fail on chain. A missing variable must not be the
// difference between the guard running and not.
//
// Set ENFORCE_FUNDING_CHECK=false to run without it deliberately. That is a decision someone makes,
// not a default they fall into.
func (c Config) validateFundingCheck() error {
	if !c.EnforceFundingCheck || !c.IsProduction() {
		return nil
	}

	var missing []string
	if !isConfiguredAddress(c.QuoteAsset()) {
		missing = append(missing, "QUOTE_ASSET_ADDRESS (or CASH_ASSET_ADDRESS)")
	}
	if !isConfiguredAddress(c.MatchingAddress) {
		missing = append(missing, "MATCHING_ADDRESS")
	}
	if strings.TrimSpace(c.ChainRPCURL) == "" {
		missing = append(missing, "CHAIN_RPC_URL")
	}
	if len(missing) == 0 {
		return nil
	}

	return fmt.Errorf(
		"APP_ENV=%s requires %s for the pre-trade funding check; "+
			"without them a buyer short of notional + fee is only caught when the trade reverts on chain. "+
			"Set them, or set ENFORCE_FUNDING_CHECK=false to run without the check deliberately",
		c.AppEnv, strings.Join(missing, ", "),
	)
}

// QuoteAsset is the asset the configured TradeModule settles the quote leg in.
//
// QUOTE_ASSET_ADDRESS falls back to CASH_ASSET_ADDRESS so a deployment predating the wrapped-quote
// migration needs no new variable and keeps reading the same contract it always did. Once the
// quote leg moves off the settlement ledger the two are different contracts, and
// QUOTE_ASSET_ADDRESS is the one that must be right -- the funding check reads it, and reading the
// cash ledger for a wrapped-quote module judges every buyer against balances the trade does not
// touch.
//
// Resolved here rather than mutated into the struct in Load so the fallback holds for a Config
// built any way, including the struct literals in tests.
func (c Config) QuoteAsset() string {
	if strings.TrimSpace(c.QuoteAssetAddress) != "" {
		return c.QuoteAssetAddress
	}
	return c.CashAssetAddress
}

// validateTradeModule refuses to start in production without TRADE_MODULE_ADDRESS.
//
// The variable used to be loaded and never read, which made it look as though the Go service
// enforced a module allowlist when the only enforcement was in execution-service. It is now what
// validateActionModule pins every submitted order to, so leaving it unset silently reopens the
// book to orders naming any module -- including the one this venue is migrating away from.
func (c Config) validateTradeModule() error {
	if !c.IsProduction() || isConfiguredAddress(c.TradeModuleAddress) {
		return nil
	}
	return fmt.Errorf(
		"APP_ENV=%s requires TRADE_MODULE_ADDRESS; without it orders naming any trade module are "+
			"accepted and rested, and a cross-module pair is only rejected after it has crossed",
		c.AppEnv,
	)
}

// PerpEnabled reports whether cNGN-PERP is configured. The asset address is the switch; the rest
// of the stack is required alongside it by validatePerpStack.
func (c Config) PerpEnabled() bool {
	return strings.TrimSpace(c.CNGNPerpAssetAddress) != ""
}

// validatePerpStack refuses a partial perp configuration, in every environment. The four addresses
// are one deployment: with the module but not the SRM the margin check would read nothing, and with
// the asset but not the module perp orders would be pinned to the spot module and rejected (or,
// worse, if the two ever matched, settled in the wrong cash).
func (c Config) validatePerpStack() error {
	fields := map[string]string{
		"CNGN_PERP_ASSET_ADDRESS":        c.CNGNPerpAssetAddress,
		"CNGN_PERP_TRADE_MODULE_ADDRESS": c.CNGNPerpTradeModuleAddress,
		"CNGN_PERP_CASH_ADDRESS":         c.CNGNPerpCashAddress,
		"CNGN_PERP_SRM_ADDRESS":          c.CNGNPerpSRMAddress,
	}
	var set, missing []string
	for _, name := range []string{"CNGN_PERP_ASSET_ADDRESS", "CNGN_PERP_TRADE_MODULE_ADDRESS", "CNGN_PERP_CASH_ADDRESS", "CNGN_PERP_SRM_ADDRESS"} {
		if isConfiguredAddress(fields[name]) {
			set = append(set, name)
		} else {
			missing = append(missing, name)
		}
	}
	if len(set) == 0 || len(missing) == 0 {
		return nil
	}
	return fmt.Errorf("the perp stack is configured partially: %s set but %s missing; set all four or none",
		strings.Join(set, ", "), strings.Join(missing, ", "))
}

func isConfiguredAddress(value string) bool {
	trimmed := strings.TrimSpace(strings.ToLower(value))
	if !strings.HasPrefix(trimmed, "0x") || len(trimmed) != 42 {
		return false
	}
	return trimmed != "0x0000000000000000000000000000000000000000"
}

func getenvDurationDefault(key string, fallback time.Duration) time.Duration {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func getenvIntDefault(key string, fallback int) int {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func getenvDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func getenvMillisecondsDuration(key string, fallbackMs int64) (time.Duration, error) {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return time.Duration(fallbackMs) * time.Millisecond, nil
	}

	ms, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return 0, err
	}
	return time.Duration(ms) * time.Millisecond, nil
}

func getenvFloatDefault(key string, fallback float64) float64 {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}

	parsed, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return fallback
	}
	return parsed
}

func getenvBool(key string, fallback bool) bool {
	value := strings.TrimSpace(strings.ToLower(os.Getenv(key)))
	if value == "" {
		return fallback
	}

	switch value {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return fallback
	}
}

// withdrawalAssets are the assets a signed withdrawal may pay out of: WITHDRAWAL_ASSET_ADDRESSES when set,
// otherwise those this venue settles in: the quote asset, the cNGN spot asset and, when the perp is
// configured, the perp stack's cash and its cNGN collateral escrow.
func withdrawalAssets(cfg Config) []string {
	if configured := getenvCSV("WITHDRAWAL_ASSET_ADDRESSES", ""); len(configured) > 0 {
		return configured
	}
	assets := make([]string, 0, 4)
	// The perp's cash is withdrawable too: it is real USDC held by that stack's CashAsset; so is
	// the cNGN its collateral escrow holds.
	for _, asset := range []string{cfg.QuoteAsset(), cfg.CNGNSpotAssetAddress, cfg.CNGNPerpCashAddress, cfg.CNGNPerpCollateralAddress} {
		if asset = strings.ToLower(strings.TrimSpace(asset)); asset != "" {
			assets = append(assets, asset)
		}
	}
	return assets
}

func getenvCSV(key string, fallback string) []string {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		raw = fallback
	}
	if strings.TrimSpace(raw) == "" {
		return nil
	}

	parts := strings.Split(raw, ",")
	values := make([]string, 0, len(parts))
	for _, part := range parts {
		trimmed := strings.ToLower(strings.TrimSpace(part))
		if trimmed == "" {
			continue
		}
		values = append(values, trimmed)
	}
	return values
}

func loadExecutorManagerData() (string, error) {
	if path := strings.TrimSpace(os.Getenv("EXECUTOR_MANAGER_DATA_FILE")); path != "" {
		data, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("read EXECUTOR_MANAGER_DATA_FILE: %w", err)
		}
		return parseExecutorManagerData(data)
	}

	value := strings.TrimSpace(os.Getenv("EXECUTOR_MANAGER_DATA"))
	if value == "" {
		return "0x", nil
	}
	return value, nil
}

func parseExecutorManagerData(data []byte) (string, error) {
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" {
		return "0x", nil
	}

	if strings.HasPrefix(trimmed, "{") {
		var payload struct {
			ManagerData string `json:"manager_data"`
		}
		if err := json.Unmarshal(data, &payload); err != nil {
			return "", fmt.Errorf("parse EXECUTOR_MANAGER_DATA_FILE json: %w", err)
		}
		if strings.TrimSpace(payload.ManagerData) == "" {
			return "", fmt.Errorf("EXECUTOR_MANAGER_DATA_FILE json missing manager_data")
		}
		return strings.TrimSpace(payload.ManagerData), nil
	}
	return trimmed, nil
}
