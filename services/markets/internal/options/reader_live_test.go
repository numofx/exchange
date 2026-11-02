package options

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/config"
)

// The reader against the live MarginEngine v2 with cNGN options attached, on an anvil fork of Base (deploy-cngn-options-v2.s.sol
// and its vault batches run there, a vol surface published): the gate reads open, and the margin estimate a writer is
// pre-checked with equals what the engine charges once the write lands. That equality is the claim options.Shortfall
// rests on for an account holding no long of the expiry.
//
// Needs, from a fork prepared that way:
//
//	OPTIONS_TEST_RPC_URL     the anvil fork
//	OPTIONS_TEST_ARTIFACT    its deployments/31337/CNGN_OPTIONS_V2.json
//	OPTIONS_TEST_OWNER       an impersonated EOA owning both accounts (anvil_impersonateAccount)
//	OPTIONS_TEST_WRITER      an engine account with cash and no options
//	OPTIONS_TEST_HOLDER      another, the counterparty
//	OPTIONS_TEST_STRIKE      a strike on the 1e-8 grid near the forward ("0.00072")
//
// Skipped without them.
func TestReaderAgainstTheLiveEngine(t *testing.T) {
	rpc := os.Getenv("OPTIONS_TEST_RPC_URL")
	if rpc == "" {
		t.Skip("set OPTIONS_TEST_RPC_URL, OPTIONS_TEST_ARTIFACT, OPTIONS_TEST_OWNER, OPTIONS_TEST_WRITER, OPTIONS_TEST_HOLDER and OPTIONS_TEST_STRIKE to run")
	}
	var artifact struct {
		Option, Manager, VolFeed, TradeModule string
		Expiry                                int64
	}
	raw, err := os.ReadFile(os.Getenv("OPTIONS_TEST_ARTIFACT"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &artifact); err != nil {
		t.Fatal(err)
	}
	fee := 300
	series := config.OptionSeries{
		AssetAddress: strings.ToLower(artifact.Option), ManagerAddress: strings.ToLower(artifact.Manager),
		VolFeedAddress: strings.ToLower(artifact.VolFeed), BaseAsset: "cNGN", Expiry: artifact.Expiry,
		Strikes: []string{os.Getenv("OPTIONS_TEST_STRIKE")}, AmountScale: "1000000000000000000000", TakerFeeBps: &fee,
	}
	contracts, err := series.Contracts()
	if err != nil {
		t.Fatal(err)
	}
	put := contracts[1] // the call, then the put
	r := NewReader(rpc, series, time.Second)
	ctx := context.Background()

	open, reason, err := r.TradingOpen(ctx, artifact.TradeModule)
	if err != nil || !open {
		t.Fatalf("the series is enabled with a live surface: open %v (%s) %v", open, reason, err)
	}

	writer, _ := new(big.Int).SetString(os.Getenv("OPTIONS_TEST_WRITER"), 10)
	holder, _ := new(big.Int).SetString(os.Getenv("OPTIONS_TEST_HOLDER"), 10)
	for _, account := range []*big.Int{writer, holder} {
		if long, err := r.HoldsLong(ctx, account); err != nil || long {
			t.Fatalf("account %s starts with no option: long %v %v", account, long, err)
		}
	}

	// The writer sells 1,000,000 cNGN of the put to the holder, no premium (a transfer): the estimate first.
	amount := new(big.Int).Mul(big.NewInt(1_000_000), oneE18)
	surplus, err := r.IMSurplus(ctx, writer)
	if err != nil {
		t.Fatal(err)
	}
	cash, err := r.Cash(ctx, writer, "0xa74e49b4ed7cb176bc02ef4d8a1a3240c9ad4272")
	if err != nil {
		t.Fatal(err)
	}
	position, err := r.Position(ctx, writer, put.SubID())
	if err != nil {
		t.Fatal(err)
	}
	isoBefore, err := r.IsolatedIM(ctx, put.StrikeWei, false, position)
	if err != nil {
		t.Fatal(err)
	}
	after := new(big.Int).Sub(position, amount)
	isoAfter, err := r.IsolatedIM(ctx, put.StrikeWei, false, after)
	if err != nil {
		t.Fatal(err)
	}
	if isoAfter.Sign() >= 0 {
		t.Fatalf("a short put carries a requirement: %s", isoAfter)
	}
	short, _, post := Shortfall(Leg{Surplus: surplus, Cash: cash, Delta: new(big.Int).Neg(amount), CashDelta: big.NewInt(0), Fee: big.NewInt(0),
		IsoBefore: isoBefore, IsoAfter: isoAfter})
	if short {
		t.Fatalf("1,000 USDC carries one short ATM put (requirement %s)", isoAfter)
	}

	// Then the write, for real.
	sendTransfer(t, rpc, os.Getenv("OPTIONS_TEST_OWNER"), writer, holder, series.AssetAddress, put.SubID(), amount)

	actual, err := r.IMSurplus(ctx, writer)
	if err != nil {
		t.Fatal(err)
	}
	diff := new(big.Int).Abs(new(big.Int).Sub(actual, post))
	// A block or two of the put's theta separates the reads: well under a thousandth of a dollar.
	if diff.Cmp(big.NewInt(1_000_000_000_000_000)) > 0 {
		t.Fatalf("estimated IM surplus %s, the engine charges %s (off by %s)", post, actual, diff)
	}
	t.Logf("requirement %s; estimated surplus after %s, engine %s, off by %s wei", isoAfter, post, actual, diff)

	if long, err := r.HoldsLong(ctx, holder); err != nil || !long {
		t.Fatalf("the holder now holds a long of the expiry: %v %v", long, err)
	}
	if long, err := r.HoldsLong(ctx, writer); err != nil || long {
		t.Fatalf("the writer holds a short, not a long: %v %v", long, err)
	}
}

// sendTransfer is SubAccounts.submitTransfers([{from, to, option, subId, amount, 0}], "") from an impersonated owner.
func sendTransfer(t *testing.T, rpc, owner string, from, to *big.Int, option, subID string, amount *big.Int) {
	t.Helper()
	sub, _ := new(big.Int).SetString(subID, 10)
	head := uintWord(big.NewInt(0x40)) + uintWord(big.NewInt(0x40+32+6*32))
	array := uintWord(big.NewInt(1)) + uintWord(from) + uintWord(to) + addressWord(option) + uintWord(sub) + intWord(amount) + uintWord(big.NewInt(0))
	data := "0x58e106d5" + head + array + uintWord(big.NewInt(0)) // submitTransfers((uint256,uint256,address,uint256,int256,bytes32)[],bytes)
	var ledger string
	if err := rpcCall(rpc, "eth_call", []any{map[string]string{"to": option, "data": sigSubAccounts}, "latest"}, &ledger); err != nil {
		t.Fatal(err)
	}
	var hash string
	if err := rpcCall(rpc, "eth_sendTransaction", []any{map[string]string{"from": owner, "to": "0x" + ledger[len(ledger)-40:], "data": data, "gas": "0x1e8480"}}, &hash); err != nil {
		t.Fatal(err)
	}
	var receipt struct{ Status string }
	for range 30 {
		if err := rpcCall(rpc, "eth_getTransactionReceipt", []any{hash}, &receipt); err == nil && receipt.Status != "" {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	if receipt.Status != "0x1" {
		t.Fatalf("the write reverted: %s", hash)
	}
}

func rpcCall(rpc, method string, params []any, out any) error {
	body, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	resp, err := http.Post(rpc, "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	var payload struct {
		Result json.RawMessage
		Error  *struct{ Message string }
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return err
	}
	if payload.Error != nil {
		return fmt.Errorf("%s: %s", method, payload.Error.Message)
	}
	if len(payload.Result) == 0 || string(payload.Result) == "null" {
		return fmt.Errorf("%s: no result", method)
	}
	return json.Unmarshal(payload.Result, out)
}
