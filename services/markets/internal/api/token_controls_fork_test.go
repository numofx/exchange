//go:build fork

// The token controls against the real tokens: an anvil fork of Base, where the issuers' own admin keys are impersonated
// to freeze and pause, and the production chain reader is asked what it sees. Not part of the default run (it needs a
// fork), and not a skip either: build it on purpose.
//
//	anvil --fork-url <base rpc> --port 18545 &
//	FORK_RPC_URL=http://127.0.0.1:18545 go test -tags fork -run Fork -count=1 ./internal/api
package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

func forkRPC(t *testing.T, url, method string, params ...any) json.RawMessage {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	resp, err := http.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("%s: %v", method, err)
	}
	defer resp.Body.Close()
	var out struct {
		Result json.RawMessage `json:"result"`
		Error  *struct{ Message string } `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || out.Error != nil {
		t.Fatalf("%s: %v %+v", method, err, out.Error)
	}
	return out.Result
}

// sendAs runs one call as `from`, impersonated, and fails the test unless it succeeds.
func sendAs(t *testing.T, url, from, to, data string) {
	t.Helper()
	forkRPC(t, url, "anvil_impersonateAccount", from)
	forkRPC(t, url, "anvil_setBalance", from, "0xde0b6b3a7640000")
	var hash string
	_ = json.Unmarshal(forkRPC(t, url, "eth_sendTransaction", map[string]string{"from": from, "to": to, "data": data}), &hash)
	for i := 0; i < 50; i++ {
		var receipt *struct{ Status string }
		_ = json.Unmarshal(forkRPC(t, url, "eth_getTransactionReceipt", hash), &receipt)
		if receipt != nil {
			if receipt.Status != "0x1" {
				t.Fatalf("%s -> %s %s reverted", from, to, data[:10])
			}
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("%s not mined", hash)
}

func ownerOf(t *testing.T, reader *chainDepositReader, contract, selector string) string {
	t.Helper()
	raw, err := reader.ethCall(context.Background(), contract, selector)
	if err != nil {
		t.Fatal(err)
	}
	address, err := decodeAddress(raw)
	if err != nil {
		t.Fatal(err)
	}
	return address
}

func TestForkTokenControlsSeeTheIssuersRealFreezesAndPauses(t *testing.T) {
	url := os.Getenv("FORK_RPC_URL")
	if url == "" {
		t.Fatal("FORK_RPC_URL is required: this test only exists to run against a fork")
	}
	reader := &chainDepositReader{chainCustodyChecker: &chainCustodyChecker{rpcURL: url, httpClient: &http.Client{Timeout: 10 * time.Second}}}
	ctx := context.Background()
	trader := "0x00000000000000000000000000000000000c0ffe"

	const (
		sigBlacklist      = "0xf9f92be4" // blacklist(address): Circle
		sigUnBlacklist    = "0x1a895266" // unBlacklist(address): Circle
		sigAddBlackList   = "0x0ecb93c0" // addBlackList(address): cNGN admin
		sigRemoveBlackLst = "0xe4997dc5" // removeBlackList(address): cNGN admin
		sigPause          = "0x8456cb59"
		sigUnpause        = "0x3f4ba83a"
		sigBlacklister    = "0xbd102430" // blacklister()
		sigPauser         = "0x9fd0506d" // pauser()
		sigOwner          = "0x8da5cb5b" // owner()
	)
	usdcBlacklister := ownerOf(t, reader, baseUSDC, sigBlacklister)
	usdcPauser := ownerOf(t, reader, baseUSDC, sigPauser)
	cngnOwner := ownerOf(t, reader, baseCNGN, sigOwner)
	adminOwner := ownerOf(t, reader, cngnAdmin, sigOwner)

	expect := func(label, asset, operation string, parties []custodyParty, status int, mention string) {
		t.Helper()
		stop, err := checkTokenControls(ctx, reader, asset, operation, parties)
		if err != nil {
			t.Fatalf("%s: %v", label, err)
		}
		if status == 0 {
			if stop != nil {
				t.Fatalf("%s: unexpected stop %+v", label, stop)
			}
			return
		}
		if stop == nil || stop.status != status || !strings.Contains(stop.message, mention) {
			t.Fatalf("%s: stop=%+v, want %d mentioning %q", label, stop, status, mention)
		}
		t.Logf("%s -> %d %s", label, stop.status, stop.message)
	}
	deposit := func(asset string) []custodyParty {
		return []custodyParty{{address: trader, role: "depositing owner"}, {address: testDepositModule, role: "deposit module", venue: true}, {address: asset, role: "custody contract", venue: true}}
	}

	expect("USDC, nothing frozen", testPerpCash, "deposit", deposit(testPerpCash), 0, "")
	expect("cNGN, nothing frozen", cngnEscrow, "deposit", deposit(cngnEscrow), 0, "")

	for _, who := range []struct {
		address, role string
		status        int
	}{{trader, "depositing owner", http.StatusBadRequest}, {testDepositModule, "deposit module", http.StatusServiceUnavailable}, {testPerpCash, "custody contract", http.StatusServiceUnavailable}} {
		sendAs(t, url, usdcBlacklister, baseUSDC, sigBlacklist+addressArg(who.address))
		expect("Circle froze the "+who.role, testPerpCash, "deposit", deposit(testPerpCash), who.status, who.role)
		sendAs(t, url, usdcBlacklister, baseUSDC, sigUnBlacklist+addressArg(who.address))
	}
	for _, who := range []struct {
		address, role string
		status        int
	}{{trader, "depositing owner", http.StatusBadRequest}, {testDepositModule, "deposit module", http.StatusServiceUnavailable}, {cngnEscrow, "custody contract", http.StatusServiceUnavailable}} {
		sendAs(t, url, adminOwner, cngnAdmin, sigAddBlackList+addressArg(who.address))
		expect("cNGN froze the "+who.role, cngnEscrow, "deposit", deposit(cngnEscrow), who.status, who.role)
		sendAs(t, url, adminOwner, cngnAdmin, sigRemoveBlackLst+addressArg(who.address))
	}

	sendAs(t, url, usdcPauser, baseUSDC, sigPause)
	expect("USDC paused", testPerpCash, "withdrawal", deposit(testPerpCash)[:1], http.StatusServiceUnavailable, "USDC is paused")
	sendAs(t, url, usdcPauser, baseUSDC, sigUnpause)
	sendAs(t, url, cngnOwner, baseCNGN, sigPause)
	expect("cNGN paused", cngnEscrow, "withdrawal", deposit(cngnEscrow)[:1], http.StatusServiceUnavailable, "cNGN is paused")
	sendAs(t, url, cngnOwner, baseCNGN, sigUnpause)

	// cNGN's admin contract has a pause too; it does not stop transfers (verified by transfer on the fork), so it must
	// not stop the venue either.
	sendAs(t, url, adminOwner, cngnAdmin, sigPause)
	expect("cNGN admin paused", cngnEscrow, "withdrawal", deposit(cngnEscrow), 0, "")
	sendAs(t, url, adminOwner, cngnAdmin, sigUnpause)
}

// escrowRoom against the real escrow and cash: the cNGN cap is read and enforced, and the cash's reverting
// totalPositionCap is read as "no cap", not as an unreadable chain.
func TestForkEscrowRoomReadsTheRealCapAndLetsCashThrough(t *testing.T) {
	url := os.Getenv("FORK_RPC_URL")
	if url == "" {
		t.Fatal("FORK_RPC_URL is required: this test only exists to run against a fork")
	}
	reader := &chainDepositReader{chainCustodyChecker: &chainCustodyChecker{rpcURL: url, httpClient: &http.Client{Timeout: 10 * time.Second}}}
	svc := &depositService{tokens: reader, manager: testDepositSRM}
	ctx := context.Background()

	if message, err := svc.escrowRoom(ctx, depositData{amount: usdc(20_000), asset: cngnEscrow, symbol: "cNGN"}); err != nil || message != "" {
		t.Fatalf("20,000 cNGN under an 8M cap: message=%q err=%v", message, err)
	}
	message, err := svc.escrowRoom(ctx, depositData{amount: usdc(8_000_000), asset: cngnEscrow, symbol: "cNGN"})
	if err != nil || !strings.Contains(message, "past its cap of 8000000 cNGN") {
		t.Fatalf("8M cNGN on top of what is posted: message=%q err=%v", message, err)
	}
	t.Logf("8M cNGN -> %s", message)
	if message, err := svc.escrowRoom(ctx, depositData{amount: usdc(1_000_000), asset: testPerpCash, symbol: "USDC"}); err != nil || message != "" {
		t.Fatalf("USDC cash has no cap: message=%q err=%v", message, err)
	}
}
