package config

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	AppEnv                 string
	APIAddr                string
	DatabaseURL            string
	MatcherPollInterval    time.Duration
	ChainRPCURL            string
	ChainID                string
	MatchingAddress        string
	EnforceMatchingCustody bool
	TradeModuleAddress     string
	ExecutorURL            string
	ExecutorManagerData    string
	ExpectedOrderOwner     string
	ExpectedOrderSigner    string
	DeribitBaseURL         string
	DeribitWSURL           string

	CNGNSpotAssetAddress          string
	CNGNJun2026FutureAssetAddress string
	CNGNJun2026FutureSubID        string
	CNGNSep2026FutureAssetAddress string
	CNGNSep2026FutureSubID        string
	CNGNNov2026FutureAssetAddress string
	CNGNNov2026FutureSubID        string
	CNGNMay2027FutureAssetAddress string
	CNGNMay2027FutureSubID        string
	EnforceActionDataInvariants   bool
	CancelProtectedOrderPrefixes  []string
}

func Load() (Config, error) {
	cfg := Config{
		AppEnv:                 getenvDefault("APP_ENV", "dev"),
		APIAddr:                getenvDefault("API_ADDR", ":8080"),
		DatabaseURL:            os.Getenv("DATABASE_URL"),
		ChainRPCURL:            getenvDefault("CHAIN_RPC_URL", os.Getenv("RPC_URL")),
		ChainID:                os.Getenv("CHAIN_ID"),
		MatchingAddress:        os.Getenv("MATCHING_ADDRESS"),
		EnforceMatchingCustody: getenvBool("ENFORCE_MATCHING_CUSTODY", true),
		TradeModuleAddress:     os.Getenv("TRADE_MODULE_ADDRESS"),
		ExecutorURL:            os.Getenv("EXECUTOR_URL"),
		ExecutorManagerData:    "0x",
		ExpectedOrderOwner:     os.Getenv("EXPECTED_ORDER_OWNER"),
		ExpectedOrderSigner:    os.Getenv("EXPECTED_ORDER_SIGNER"),
		DeribitBaseURL:         getenvDefault("DERIBIT_BASE_URL", "https://test.deribit.com/api/v2"),
		DeribitWSURL:           getenvDefault("DERIBIT_WS_URL", "wss://test.deribit.com/ws/api/v2"),

		CNGNSpotAssetAddress:          strings.ToLower(strings.TrimSpace(os.Getenv("CNGN_SPOT_ASSET_ADDRESS"))),
		CNGNJun2026FutureAssetAddress: strings.ToLower(strings.TrimSpace(os.Getenv("CNGN_JUN30_2026_FUTURE_ASSET_ADDRESS"))),
		CNGNJun2026FutureSubID:        strings.TrimSpace(os.Getenv("CNGN_JUN30_2026_FUTURE_SUB_ID")),
		CNGNSep2026FutureAssetAddress: strings.ToLower(strings.TrimSpace(os.Getenv("CNGN_SEP16_2026_FUTURE_ASSET_ADDRESS"))),
		CNGNSep2026FutureSubID:        strings.TrimSpace(os.Getenv("CNGN_SEP16_2026_FUTURE_SUB_ID")),
		CNGNNov2026FutureAssetAddress: strings.ToLower(strings.TrimSpace(os.Getenv("CNGN_NOV30_2026_FUTURE_ASSET_ADDRESS"))),
		CNGNNov2026FutureSubID:        strings.TrimSpace(os.Getenv("CNGN_NOV30_2026_FUTURE_SUB_ID")),
		CNGNMay2027FutureAssetAddress: strings.ToLower(strings.TrimSpace(os.Getenv("CNGN_MAY31_2027_FUTURE_ASSET_ADDRESS"))),
		CNGNMay2027FutureSubID:        strings.TrimSpace(os.Getenv("CNGN_MAY31_2027_FUTURE_SUB_ID")),
		EnforceActionDataInvariants:   getenvBool("ENFORCE_ACTION_DATA_INVARIANTS", true),
		CancelProtectedOrderPrefixes:  getenvCSV("CANCEL_PROTECTED_ORDER_ID_PREFIXES", "validation:,smoke:,manual:"),
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

	return cfg, nil
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
