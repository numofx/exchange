package api

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"math/big"
	"strings"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
	"github.com/numofx/matching-backend/internal/pricing"
)

type createOrderRequest struct {
	OrderID        string           `json:"order_id"`
	OwnerAddress   string           `json:"owner_address"`
	SignerAddress  string           `json:"signer_address"`
	SubaccountID   string           `json:"subaccount_id"`
	RecipientID    string           `json:"recipient_id"`
	Nonce          string           `json:"nonce"`
	Side           string           `json:"side"`
	AssetAddress   string           `json:"asset_address"`
	SubID          string           `json:"sub_id"`
	DesiredAmount  string           `json:"desired_amount"`
	FilledAmount   string           `json:"filled_amount"`
	LimitPrice     string           `json:"limit_price"`
	WorstFee       string           `json:"worst_fee"`
	Expiry         int64            `json:"expiry"`

	ActionJSON     json.RawMessage  `json:"action_json"`
	Signature      string           `json:"signature"`
}

func (r createOrderRequest) toParams(cfg config.Config) (orders.CreateOrderParams, error) {
	if r.OrderID == "" {
		return orders.CreateOrderParams{}, fmt.Errorf("order_id is required")
	}
	if r.OwnerAddress == "" {
		return orders.CreateOrderParams{}, fmt.Errorf("owner_address is required")
	}
	if r.SignerAddress == "" {
		return orders.CreateOrderParams{}, fmt.Errorf("signer_address is required")
	}
	if r.SubaccountID == "" {
		return orders.CreateOrderParams{}, fmt.Errorf("subaccount_id is required")
	}
	if r.RecipientID == "" {
		return orders.CreateOrderParams{}, fmt.Errorf("recipient_id is required")
	}
	if r.Nonce == "" {
		return orders.CreateOrderParams{}, fmt.Errorf("nonce is required")
	}
	if r.AssetAddress == "" {
		return orders.CreateOrderParams{}, fmt.Errorf("asset_address is required")
	}
	if r.DesiredAmount == "" {
		return orders.CreateOrderParams{}, fmt.Errorf("desired_amount is required")
	}
	if r.LimitPrice == "" {
		return orders.CreateOrderParams{}, fmt.Errorf("limit_price is required")
	}
	if r.WorstFee == "" {
		return orders.CreateOrderParams{}, fmt.Errorf("worst_fee is required")
	}
	if r.Signature == "" {
		return orders.CreateOrderParams{}, fmt.Errorf("signature is required")
	}
	if r.Expiry <= time.Now().Unix() {
		return orders.CreateOrderParams{}, fmt.Errorf("expiry must be in the future")
	}
	if !json.Valid(r.ActionJSON) {
		return orders.CreateOrderParams{}, fmt.Errorf("action_json must be valid JSON")
	}

	ownerAddress := strings.ToLower(r.OwnerAddress)
	signerAddress := strings.ToLower(r.SignerAddress)

	if expectedOwner := strings.ToLower(strings.TrimSpace(cfg.ExpectedOrderOwner)); expectedOwner != "" && ownerAddress != expectedOwner {
		return orders.CreateOrderParams{}, fmt.Errorf("owner_address must match configured expected owner")
	}
	if expectedSigner := strings.ToLower(strings.TrimSpace(cfg.ExpectedOrderSigner)); expectedSigner != "" && signerAddress != expectedSigner {
		return orders.CreateOrderParams{}, fmt.Errorf("signer_address must match configured expected signer")
	}

	side := orders.Side(strings.ToLower(r.Side))
	if side != "" && side != orders.SideBuy && side != orders.SideSell {
		return orders.CreateOrderParams{}, fmt.Errorf("side must be 'buy' or 'sell'")
	}

	assetAddress := strings.ToLower(r.AssetAddress)
	subID := r.SubID
	if subID == "" {
		subID = "0"
	}

	if !isAllowedInstrument(cfg, assetAddress, subID) {
		return orders.CreateOrderParams{}, fmt.Errorf("asset_address must match a configured instrument")
	}
	registry := instruments.DefaultRegistry(cfg)
	instrument, ok := registry.ByAssetAndSubID(assetAddress, subID)
	if !ok {
		instrument = instruments.Metadata{
			Symbol:         assetAddress,
			AssetAddress:   assetAddress,
			SubID:          subID,
			TickSize:       "1",
			QuotePrecision: 8,
		}
	}

	converter, err := pricing.NewConverter(instrument)
	if err != nil {
		return orders.CreateOrderParams{}, err
	}
	limitPriceTicks, normalizedPrice, err := converter.Parse(r.LimitPrice)
	if err != nil {
		return orders.CreateOrderParams{}, err
	}

	filledAmount := r.FilledAmount
	if filledAmount == "" {
		filledAmount = "0"
	}
	normalizedDesiredAmount, err := normalizeDesiredAmount(instrument, r.DesiredAmount)
	if err != nil {
		return orders.CreateOrderParams{}, err
	}
	normalizedFilledAmount, err := normalizeFilledAmount(instrument, filledAmount)
	if err != nil {
		return orders.CreateOrderParams{}, err
	}
	filledCmpDesired, err := compareIntegerStrings(normalizedFilledAmount, normalizedDesiredAmount)
	if err != nil {
		return orders.CreateOrderParams{}, err
	}
	if filledCmpDesired > 0 {
		return orders.CreateOrderParams{}, fmt.Errorf("filled_amount cannot exceed desired_amount")
	}

	if err := validateActionJSON(r.ActionJSON, ownerAddress, signerAddress, r.SubaccountID, r.Nonce); err != nil {
		return orders.CreateOrderParams{}, err
	}
	if cfg.EnforceActionDataInvariants {
		if err := validateActionDataInvariants(r.ActionJSON, side, assetAddress, subID, limitPriceTicks, normalizedDesiredAmount, instrument); err != nil {
			return orders.CreateOrderParams{}, err
		}
	}

	return orders.CreateOrderParams{
		OrderID:         r.OrderID,
		OwnerAddress:    ownerAddress,
		SignerAddress:   signerAddress,
		SubaccountID:    r.SubaccountID,
		RecipientID:     r.RecipientID,
		Nonce:           r.Nonce,
		Side:            side,
		AssetAddress:    assetAddress,
		SubID:           subID,
		DesiredAmount:   normalizedDesiredAmount,
		FilledAmount:    normalizedFilledAmount,
		LimitPrice:      normalizedPrice,
		LimitPriceTicks: limitPriceTicks,
		WorstFee:        r.WorstFee,
		Expiry:          r.Expiry,
		ActionJSON:      r.ActionJSON,
		Signature:       r.Signature,
	}, nil
}

func normalizeDesiredAmount(instrument instruments.Metadata, raw string) (string, error) {
	return normalizeAmountToAtomicUnits("desired_amount", instrument, raw, true)
}

func normalizeFilledAmount(instrument instruments.Metadata, raw string) (string, error) {
	return normalizeAmountToAtomicUnits("filled_amount", instrument, raw, false)
}

func normalizeAmountToAtomicUnits(field string, instrument instruments.Metadata, raw string, requirePositive bool) (string, error) {
	value, err := parseDecimal(raw)
	if err != nil {
		return "", fmt.Errorf("%s: %w", field, err)
	}

	stepRaw := amountAtomicStep(instrument)
	step, err := parseDecimal(stepRaw)
	if err != nil {
		return "", fmt.Errorf("invalid amount step %q for market %s", stepRaw, instrument.Symbol)
	}
	if step.Sign() <= 0 {
		return "", fmt.Errorf("invalid amount step %q for market %s", stepRaw, instrument.Symbol)
	}

	atomicRat := new(big.Rat).Quo(value, step)
	if !atomicRat.IsInt() {
		return "", fmt.Errorf("%s must align to amount step %s", field, normalizeDecimalString(stepRaw))
	}

	atomic := new(big.Int).Set(atomicRat.Num())
	if requirePositive {
		if atomic.Sign() == 0 {
			return "", fmt.Errorf("normalized atomic size is 0")
		}
		if atomic.Sign() < 0 {
			return "", fmt.Errorf("desired_amount must be greater than zero")
		}
	} else if atomic.Sign() < 0 {
		return "", fmt.Errorf("filled_amount cannot be negative")
	}

	return atomic.String(), nil
}

func amountAtomicStep(instrument instruments.Metadata) string {
	if instrument.Symbol == instruments.CNGNJun2026Symbol || instrument.Symbol == instruments.CNGNNov2026Symbol || instrument.Symbol == instruments.CNGNMay2027Symbol {
		return instrument.MinSize
	}
	return "1"
}

func compareIntegerStrings(a string, b string) (int, error) {
	left, ok := new(big.Int).SetString(strings.TrimSpace(a), 10)
	if !ok {
		return 0, fmt.Errorf("invalid integer value %q", a)
	}
	right, ok := new(big.Int).SetString(strings.TrimSpace(b), 10)
	if !ok {
		return 0, fmt.Errorf("invalid integer value %q", b)
	}
	return left.Cmp(right), nil
}

type cancelOrderRequest struct {
	OwnerAddress string `json:"owner_address"`
	Nonce        string `json:"nonce"`
	Reason       string `json:"reason"`
	Service      string `json:"service"`
}

func (r cancelOrderRequest) validate() error {
	if r.OwnerAddress == "" {
		return fmt.Errorf("owner_address is required")
	}
	if r.Nonce == "" {
		return fmt.Errorf("nonce is required")
	}
	return nil
}

func isAllowedInstrument(cfg config.Config, assetAddress string, subID string) bool {
	registry := instruments.DefaultRegistry(cfg)
	if len(registry.Enabled()) == 0 {
		return true
	}
	_, ok := registry.ByAssetAndSubID(assetAddress, subID)
	return ok
}

type parsedTradeActionData struct {
	AssetAddress  string
	SubID         string
	LimitPrice    *big.Int
	DesiredAmount *big.Int
	IsBid         bool
}

func validateActionDataInvariants(raw json.RawMessage, side orders.Side, assetAddress string, subID string, limitPriceTicks string, desiredAmountAtomic string, instrument instruments.Metadata) error {
	action, err := parseActionTradeData(raw)
	if err != nil {
		return fmt.Errorf("action_json.data invariant check failed: %w", err)
	}
	if action.AssetAddress != strings.ToLower(assetAddress) {
		return fmt.Errorf("action_json.data.asset must match asset_address")
	}
	if action.SubID != strings.TrimSpace(subID) {
		return fmt.Errorf("action_json.data.subId must match sub_id")
	}

	expectBid := side == orders.SideBuy
	if action.IsBid != expectBid {
		return fmt.Errorf("action_json.data.isBid must match side")
	}

	priceTicksInt, err := parsePositiveIntString(limitPriceTicks, "limit_price_ticks")
	if err != nil {
		return err
	}
	desiredAtomicInt, err := parsePositiveIntString(desiredAmountAtomic, "desired_amount")
	if err != nil {
		return err
	}

	priceScale, priceRem := new(big.Int).QuoRem(action.LimitPrice, priceTicksInt, new(big.Int))
	if priceRem.Sign() != 0 || priceScale.Sign() <= 0 {
		return fmt.Errorf("action_json.data.limitPrice is not aligned with normalized limit_price")
	}
	amountScale, amountRem := new(big.Int).QuoRem(action.DesiredAmount, desiredAtomicInt, new(big.Int))
	if amountRem.Sign() == 0 && amountScale.Sign() > 0 {
		return nil
	}

	compatReason := "not_divisible"
	compatPass := false
	stepRaw := amountAtomicStep(instrument)
	if compatScale, ok := reciprocalScale(stepRaw); ok {
		expected := new(big.Int).Mul(action.DesiredAmount, compatScale)
		if expected.Cmp(desiredAtomicInt) == 0 {
			compatPass = true
			compatReason = "raw_desired_amount_compat_mode"
		} else {
			compatReason = "raw_desired_amount_mismatch"
		}
	} else {
		compatReason = "non_integer_reciprocal_step"
	}

	slog.Warn(
		"order_action_desired_amount_alignment_mismatch",
		"market_symbol", instrument.Symbol,
		"quote_precision", instrument.QuotePrecision,
		"contract_multiplier", instrument.ContractMultiplier,
		"tick_size", instrument.TickSize,
		"lot_size", stepRaw,
		"incoming_action_desired_amount", action.DesiredAmount.String(),
		"normalized_desired_amount", desiredAmountAtomic,
		"parsed_action_desired_amount_raw", action.DesiredAmount.String(),
		"amount_scale", amountScale.String(),
		"amount_remainder", amountRem.String(),
		"reason", compatReason,
	)

	if compatPass {
		return nil
	}
	return fmt.Errorf("action_json.data.desiredAmount is not aligned with normalized desired_amount")
}

func reciprocalScale(raw string) (*big.Int, bool) {
	stepRat, ok := new(big.Rat).SetString(strings.TrimSpace(raw))
	if !ok || stepRat.Sign() <= 0 {
		return nil, false
	}
	reciprocal := new(big.Rat).Inv(stepRat)
	if !reciprocal.IsInt() {
		return nil, false
	}
	return new(big.Int).Set(reciprocal.Num()), true
}

func parseActionTradeData(raw json.RawMessage) (parsedTradeActionData, error) {
	var action struct {
		Data string `json:"data"`
	}
	if err := json.Unmarshal(raw, &action); err != nil {
		return parsedTradeActionData{}, fmt.Errorf("parse action_json: %w", err)
	}
	hexValue := strings.TrimPrefix(strings.ToLower(strings.TrimSpace(action.Data)), "0x")
	if len(hexValue) != 64*7 {
		return parsedTradeActionData{}, fmt.Errorf("expected encoded TradeData tuple")
	}
	payload, err := hex.DecodeString(hexValue)
	if err != nil {
		return parsedTradeActionData{}, fmt.Errorf("decode action_json.data: %w", err)
	}

	word := func(i int) []byte {
		start := i * 32
		return payload[start : start+32]
	}

	assetAddress := "0x" + hex.EncodeToString(word(0)[12:])
	subID := new(big.Int).SetBytes(word(1)).String()
	limitPrice := signedWordToBigInt(word(2))
	desiredAmount := signedWordToBigInt(word(3))
	isBid := new(big.Int).SetBytes(word(6)).Cmp(big.NewInt(0)) != 0

	if limitPrice.Sign() <= 0 {
		return parsedTradeActionData{}, fmt.Errorf("action_json.data.limitPrice must be positive")
	}
	if desiredAmount.Sign() <= 0 {
		return parsedTradeActionData{}, fmt.Errorf("action_json.data.desiredAmount must be positive")
	}

	return parsedTradeActionData{
		AssetAddress:  strings.ToLower(assetAddress),
		SubID:         subID,
		LimitPrice:    limitPrice,
		DesiredAmount: desiredAmount,
		IsBid:         isBid,
	}, nil
}

func signedWordToBigInt(word []byte) *big.Int {
	value := new(big.Int).SetBytes(word)
	if len(word) != 32 {
		return value
	}
	if word[0]&0x80 == 0 {
		return value
	}
	two256 := new(big.Int).Lsh(big.NewInt(1), 256)
	return value.Sub(value, two256)
}

func parsePositiveIntString(raw string, field string) (*big.Int, error) {
	value, ok := new(big.Int).SetString(strings.TrimSpace(raw), 10)
	if !ok {
		return nil, fmt.Errorf("invalid %s", field)
	}
	if value.Sign() <= 0 {
		return nil, fmt.Errorf("%s must be positive", field)
	}
	return value, nil
}

func validateActionJSON(raw json.RawMessage, ownerAddress string, signerAddress string, subaccountID string, nonce string) error {
	var action struct {
		SubaccountID string `json:"subaccount_id"`
		Nonce        string `json:"nonce"`
		Owner        string `json:"owner"`
		Signer       string `json:"signer"`
	}

	if err := json.Unmarshal(raw, &action); err != nil {
		return fmt.Errorf("parse action_json: %w", err)
	}
	if action.SubaccountID != subaccountID {
		return fmt.Errorf("action_json.subaccount_id must match subaccount_id")
	}
	if action.Nonce != nonce {
		return fmt.Errorf("action_json.nonce must match nonce")
	}
	if strings.ToLower(action.Owner) != ownerAddress {
		return fmt.Errorf("action_json.owner must match owner_address")
	}
	if strings.ToLower(action.Signer) != signerAddress {
		return fmt.Errorf("action_json.signer must match signer_address")
	}
	return nil
}
