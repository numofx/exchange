package api

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/numofx/matching-backend/internal/config"
)

const zeroAddress = "0x0000000000000000000000000000000000000000"

type custodyChecker interface {
	ValidateDeposited(ctx context.Context, subaccountID string) error
}

type rejectingCustodyChecker struct {
	err error
}

func (r rejectingCustodyChecker) ValidateDeposited(context.Context, string) error {
	return r.err
}

type chainCustodyChecker struct {
	rpcURL          string
	matchingAddress string
	httpClient      *http.Client

	mu              sync.RWMutex
	subAccountsAddr string
}

func newCustodyChecker(cfg config.Config) custodyChecker {
	if !cfg.EnforceMatchingCustody {
		return nil
	}
	if !isHexAddress(cfg.MatchingAddress) {
		return nil
	}
	if strings.TrimSpace(cfg.ChainRPCURL) == "" {
		return rejectingCustodyChecker{err: fmt.Errorf("custody guard misconfigured: CHAIN_RPC_URL is required")}
	}

	return &chainCustodyChecker{
		rpcURL:          strings.TrimSpace(cfg.ChainRPCURL),
		matchingAddress: strings.ToLower(strings.TrimSpace(cfg.MatchingAddress)),
		httpClient:      &http.Client{Timeout: 5 * time.Second},
	}
}

func (c *chainCustodyChecker) ValidateDeposited(ctx context.Context, subaccountID string) error {
	subaccountID = strings.TrimSpace(subaccountID)
	if subaccountID == "" {
		return fmt.Errorf("subaccount_id is required")
	}

	subAccountsAddress, err := c.subAccountsAddress(ctx)
	if err != nil {
		return fmt.Errorf("resolve subaccounts contract: %w", err)
	}

	owner, err := c.callAddress(ctx, subAccountsAddress, "0x6352211e", subaccountID)
	if err != nil {
		return fmt.Errorf("read subaccount owner: %w", err)
	}
	if owner != c.matchingAddress {
		return fmt.Errorf("subaccount_id %s is not deposited in matching custody", subaccountID)
	}

	recordedOwner, err := c.callAddress(ctx, c.matchingAddress, "0x63f1ddaa", subaccountID)
	if err != nil {
		return fmt.Errorf("read subaccount ownership record: %w", err)
	}
	if recordedOwner == zeroAddress {
		return fmt.Errorf("subaccount_id %s has no owner recorded in matching", subaccountID)
	}

	return nil
}

func (c *chainCustodyChecker) subAccountsAddress(ctx context.Context) (string, error) {
	c.mu.RLock()
	cached := c.subAccountsAddr
	c.mu.RUnlock()
	if cached != "" {
		return cached, nil
	}

	resultHex, err := c.ethCall(ctx, c.matchingAddress, "0x779e5012")
	if err != nil {
		return "", err
	}
	address, err := decodeAddress(resultHex)
	if err != nil {
		return "", err
	}

	c.mu.Lock()
	c.subAccountsAddr = address
	c.mu.Unlock()
	return address, nil
}

func (c *chainCustodyChecker) callAddress(ctx context.Context, contractAddress string, selector string, subaccountID string) (string, error) {
	encodedID, err := encodeUint256(subaccountID)
	if err != nil {
		return "", err
	}
	resultHex, err := c.ethCall(ctx, contractAddress, selector+encodedID)
	if err != nil {
		return "", err
	}
	return decodeAddress(resultHex)
}

func (c *chainCustodyChecker) ethCall(ctx context.Context, contractAddress string, data string) (string, error) {
	body := map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "eth_call",
		"params": []any{
			map[string]string{
				"to":   contractAddress,
				"data": data,
			},
			"latest",
		},
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.rpcURL, bytes.NewReader(raw))
	if err != nil {
		return "", err
	}
	req.Header.Set("content-type", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("rpc status %d", resp.StatusCode)
	}

	var payload struct {
		Result string `json:"result"`
		Error  *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return "", err
	}
	if payload.Error != nil {
		return "", errors.New(payload.Error.Message)
	}
	if payload.Result == "" {
		return "", fmt.Errorf("empty rpc result")
	}
	return strings.ToLower(payload.Result), nil
}

func encodeUint256(raw string) (string, error) {
	value, ok := new(big.Int).SetString(strings.TrimSpace(raw), 10)
	if !ok || value.Sign() < 0 {
		return "", fmt.Errorf("invalid subaccount_id %q", raw)
	}
	return fmt.Sprintf("%064x", value), nil
}

func decodeAddress(data string) (string, error) {
	cleaned := strings.TrimSpace(strings.ToLower(data))
	if !strings.HasPrefix(cleaned, "0x") {
		return "", fmt.Errorf("invalid address payload")
	}
	hexValue := cleaned[2:]
	if len(hexValue) < 64 {
		hexValue = strings.Repeat("0", 64-len(hexValue)) + hexValue
	}
	if len(hexValue) < 40 {
		return "", fmt.Errorf("address payload too short")
	}
	last40 := hexValue[len(hexValue)-40:]
	if _, err := hex.DecodeString(last40); err != nil {
		return "", fmt.Errorf("invalid address payload")
	}
	return "0x" + last40, nil
}

func isHexAddress(value string) bool {
	cleaned := strings.TrimSpace(strings.ToLower(value))
	if len(cleaned) != 42 || !strings.HasPrefix(cleaned, "0x") {
		return false
	}
	_, err := hex.DecodeString(cleaned[2:])
	return err == nil
}
