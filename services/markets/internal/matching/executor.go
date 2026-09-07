package matching

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/numofx/matching-backend/internal/orders"
)

// makerFillFeeZero is the fee charged on every maker fill. Maker fees are
// guaranteed 0.00% across all markets, so this is always "0" — do not make it
// per-market or configurable without also lifting the enforcement in
// execution-service (which rejects any non-zero maker fill fee before it
// reaches the chain).
const makerFillFeeZero = "0"

// takerFillFee is the fee charged on every taker fill, and the SINGLE source of truth for it.
// It is both submitted to execution-service and reserved against the buyer's cash by
// buyerCanFund, because the two must agree: TradeModule appends the fee as a third quote-asset
// transfer in the same batch, so a buyer funded to notional-only reverts SRM_NoNegativeCash.
//
// Raising this above "0" is therefore not a one-line change to the request builder -- it is a
// change to what the matcher must reserve before crossing. Keep them reading the same constant.
const takerFillFee = "0"

type ExecutorClient struct {
	url         string
	managerData string
	httpClient  *http.Client
}

type ExecutorRequest struct {
	Market        string            `json:"market"`
	AssetAddress  string            `json:"asset_address"`
	ModuleAddress string            `json:"module_address"`
	MakerOrderID  string            `json:"maker_order_id"`
	TakerOrderID  string            `json:"taker_order_id"`
	Actions       []json.RawMessage `json:"actions"`
	Signatures    []string          `json:"signatures"`
	OrderData     TradeOrderData    `json:"order_data"`
}

type TradeOrderData struct {
	TakerAccount string            `json:"taker_account"`
	TakerFee     string            `json:"taker_fee"`
	FillDetails  []TradeFillDetail `json:"fill_details"`
	ManagerData  string            `json:"manager_data"`
}

type TradeFillDetail struct {
	FilledAccount string `json:"filled_account"`
	AmountFilled  string `json:"amount_filled"`
	// Price is always the canonical internal price. For BTCVAR30-PERP that means
	// variance-price ticks, not vol points.
	Price string `json:"price"`
	Fee   string `json:"fee"`
}

type ExecutorResponse struct {
	Accepted bool   `json:"accepted"`
	TxHash   string `json:"tx_hash"`
	Error    string `json:"error"`
	// Present only when execution-service waited for a receipt. Previously absent
	// from this struct, so json.Unmarshal discarded them and a reverted transaction
	// was indistinguishable from a settled one.
	ReceiptStatus string `json:"receipt_status"`
	BlockNumber   string `json:"block_number"`
}

var evmAddressPattern = regexp.MustCompile(`^0x[0-9a-fA-F]{40}$`)

// NewExecutorClient builds the client. timeout bounds the entire request/response
// exchange, receipt wait included; see config.Config.ExecutorTimeout for why it must
// outlast execution-service's own receipt timeout.
func NewExecutorClient(url string, managerData string, timeout time.Duration) *ExecutorClient {
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	return &ExecutorClient{
		url:         strings.TrimSpace(url),
		managerData: strings.TrimSpace(managerData),
		httpClient: &http.Client{
			Timeout: timeout,
		},
	}
}

func (c *ExecutorClient) SubmitMatchForMarket(ctx context.Context, market string, candidate orders.MatchCandidate, price string, amount string) (ExecutorResponse, error) {
	if c.url == "" {
		return ExecutorResponse{}, fmt.Errorf("EXECUTOR_URL is required")
	}

	reqBody, err := buildExecutorRequest(market, candidate, c.managerData, price, amount)
	if err != nil {
		return ExecutorResponse{}, err
	}

	payload, err := json.Marshal(reqBody)
	if err != nil {
		return ExecutorResponse{}, err
	}
	slog.Info(
		"match_trace_executor_payload",
		"executor_url", c.url,
		"market", reqBody.Market,
		"asset_address", reqBody.AssetAddress,
		"module_address", reqBody.ModuleAddress,
		"maker_order_id", reqBody.MakerOrderID,
		"taker_order_id", reqBody.TakerOrderID,
		"payload_json", string(payload),
	)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url, bytes.NewReader(payload))
	if err != nil {
		return ExecutorResponse{}, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return ExecutorResponse{}, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return ExecutorResponse{}, err
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		if len(body) == 0 {
			return ExecutorResponse{}, fmt.Errorf("executor returned status %d", resp.StatusCode)
		}
		return ExecutorResponse{}, fmt.Errorf("executor returned status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	if len(bytes.TrimSpace(body)) == 0 {
		return ExecutorResponse{Accepted: true}, nil
	}

	var executorResp ExecutorResponse
	if err := json.Unmarshal(body, &executorResp); err != nil {
		return ExecutorResponse{}, fmt.Errorf("decode executor response: %w", err)
	}
	if executorResp.Error != "" {
		return ExecutorResponse{}, fmt.Errorf("executor rejected match: %s", executorResp.Error)
	}
	if !executorResp.Accepted && executorResp.TxHash == "" {
		// Legacy shim: an older execution-service replied {} to mean "submitted".
		// Absent a tx hash there is nothing on chain to disagree with.
		executorResp.Accepted = true
	}
	if !executorResp.Accepted && strings.EqualFold(executorResp.ReceiptStatus, "timeout") {
		// The transaction was broadcast and may still mine. Retrying would simulate
		// against a nonce whose fill has not landed, pass, and put a second
		// verifyAndMatch on the wire for a fill already in flight.
		return executorResp, &outcomeUnknownError{message: fmt.Sprintf(
			"executor outcome unknown: tx %s still pending after receipt wait",
			defaultIfEmpty(executorResp.TxHash, "unknown"),
		)}
	}
	if !executorResp.Accepted {
		// A mined-and-reverted transaction lands here. Returning it as an error keeps
		// every non-acceptance on the one path that backs off and releases the pair,
		// so no caller can reach FinalizeMatchWithPrice with an unsettled fill.
		return executorResp, &notAcceptedError{message: fmt.Sprintf(
			"executor did not accept match: tx %s receipt_status=%s block=%s",
			executorResp.TxHash,
			defaultIfEmpty(executorResp.ReceiptStatus, "unknown"),
			defaultIfEmpty(executorResp.BlockNumber, "unknown"),
		)}
	}
	return executorResp, nil
}

func buildExecutorRequest(market string, candidate orders.MatchCandidate, managerData string, price string, amount string) (ExecutorRequest, error) {
	if !isEVMAddress(candidate.Taker.AssetAddress) {
		return ExecutorRequest{}, fmt.Errorf("invalid asset address %q", candidate.Taker.AssetAddress)
	}

	takerAction, err := normalizeAction(candidate.Taker)
	if err != nil {
		return ExecutorRequest{}, fmt.Errorf("parse taker action_json: %w", err)
	}
	makerAction, err := normalizeAction(candidate.Maker)
	if err != nil {
		return ExecutorRequest{}, fmt.Errorf("parse maker action_json: %w", err)
	}

	moduleAddress := extractModuleAddress(takerAction)
	if !isEVMAddress(moduleAddress) {
		return ExecutorRequest{}, fmt.Errorf("invalid taker module address %q", moduleAddress)
	}
	makerModuleAddress := extractModuleAddress(makerAction)
	if makerModuleAddress != moduleAddress {
		return ExecutorRequest{}, fmt.Errorf("maker module address mismatch: taker=%s maker=%s", moduleAddress, makerModuleAddress)
	}

	return ExecutorRequest{
		Market:        market,
		AssetAddress:  strings.ToLower(candidate.Taker.AssetAddress),
		ModuleAddress: moduleAddress,
		MakerOrderID:  candidate.Maker.OrderID,
		TakerOrderID:  candidate.Taker.OrderID,
		Actions:       []json.RawMessage{takerAction, makerAction},
		Signatures:    []string{candidate.Taker.Signature, candidate.Maker.Signature},
		OrderData: TradeOrderData{
			TakerAccount: candidate.Taker.SubaccountID,
			TakerFee:     takerFillFee,
			FillDetails: []TradeFillDetail{
				{
					FilledAccount: candidate.Maker.SubaccountID,
					AmountFilled:  amount,
					Price:         price,
					Fee:           makerFillFeeZero,
				},
			},
			ManagerData: defaultManagerData(managerData),
		},
	}, nil
}

func defaultManagerData(managerData string) string {
	trimmed := strings.TrimSpace(managerData)
	if trimmed == "" {
		return "0x"
	}
	return trimmed
}

func normalizeAction(order orders.Order) (json.RawMessage, error) {
	raw := order.ActionJSON
	if !json.Valid(raw) {
		return nil, fmt.Errorf("invalid json")
	}

	var action map[string]any
	if err := json.Unmarshal(raw, &action); err != nil {
		return nil, err
	}

	required := []string{"subaccount_id", "nonce", "module", "data", "expiry", "owner", "signer"}
	for _, field := range required {
		if _, ok := action[field]; !ok {
			return nil, fmt.Errorf("missing %s", field)
		}
	}

	if actionSubaccount, ok := action["subaccount_id"].(string); !ok || actionSubaccount != order.SubaccountID {
		return nil, fmt.Errorf("subaccount_id mismatch")
	}
	if actionNonce, ok := action["nonce"].(string); !ok || actionNonce != order.Nonce {
		return nil, fmt.Errorf("nonce mismatch")
	}
	if actionOwner, ok := action["owner"].(string); !ok || strings.ToLower(actionOwner) != strings.ToLower(order.OwnerAddress) {
		return nil, fmt.Errorf("owner mismatch")
	}
	if actionSigner, ok := action["signer"].(string); !ok || strings.ToLower(actionSigner) != strings.ToLower(order.SignerAddress) {
		return nil, fmt.Errorf("signer mismatch")
	}
	module, _ := action["module"].(string)
	owner, _ := action["owner"].(string)
	signer, _ := action["signer"].(string)
	if !isEVMAddress(module) {
		return nil, fmt.Errorf("module must be a 20-byte 0x address")
	}
	if !isEVMAddress(owner) {
		return nil, fmt.Errorf("owner must be a 20-byte 0x address")
	}
	if !isEVMAddress(signer) {
		return nil, fmt.Errorf("signer must be a 20-byte 0x address")
	}
	action["module"] = strings.ToLower(module)
	action["owner"] = strings.ToLower(owner)
	action["signer"] = strings.ToLower(signer)

	normalized, err := json.Marshal(action)
	if err != nil {
		return nil, err
	}
	return normalized, nil
}

func extractModuleAddress(raw json.RawMessage) string {
	var action struct {
		Module string `json:"module"`
	}
	if err := json.Unmarshal(raw, &action); err != nil {
		return ""
	}
	return strings.ToLower(action.Module)
}

func isEVMAddress(value string) bool {
	return evmAddressPattern.MatchString(strings.TrimSpace(value))
}

func defaultIfEmpty(value string, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

// notAcceptedError marks a response execution-service explicitly refused -- today,
// a transaction that mined and reverted. It is a distinct type rather than a
// message so that classification never depends on the message text: a transaction
// hash can begin with the TM_FillLimitCrossed selector's digits by chance, and
// substring-matching one would read a revert as an already-settled fill.
type notAcceptedError struct {
	message string
}

func (e *notAcceptedError) Error() string {
	return e.message
}

// outcomeUnknownError marks a match whose on-chain result could not be determined:
// the transaction is broadcast and may yet mine. Distinct from notAcceptedError,
// which means it definitely did not settle. The two demand opposite responses --
// a refusal is safe to retry, an unknown outcome is not.
type outcomeUnknownError struct {
	message string
}

func (e *outcomeUnknownError) Error() string {
	return e.message
}
