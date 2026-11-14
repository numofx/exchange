package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// custodyStub is a chain where Matching holds subaccount 7 (and records an owner) but not 8, counting its calls.
func custodyStub(matching string) (*httptest.Server, *atomic.Int32) {
	var calls atomic.Int32
	word := func(addr string) string { return "0x" + strings.Repeat("0", 24) + strings.TrimPrefix(addr, "0x") }
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		var req struct {
			Params []json.RawMessage `json:"params"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		var call struct{ Data string }
		_ = json.Unmarshal(req.Params[0], &call)
		result := word("0x" + strings.Repeat("5a", 20)) // SubAccounts, and the recorded owner
		if strings.HasPrefix(call.Data, "0x6352211e") { // ownerOf
			result = word(matching)
			if strings.HasSuffix(call.Data, "8") {
				result = word("0x" + strings.Repeat("99", 20))
			}
		}
		fmt.Fprintf(w, `{"jsonrpc":"2.0","id":1,"result":%q}`, result)
	})), &calls
}

func TestConfirmedCustodyIsReadOnceForMany(t *testing.T) {
	matching := "0x" + strings.Repeat("ab", 20)
	rpc, calls := custodyStub(matching)
	defer rpc.Close()
	clock := time.Unix(1_800_000_000, 0)
	c := &chainCustodyChecker{rpcURL: rpc.URL, matchingAddress: matching, httpClient: rpc.Client(), now: func() time.Time { return clock }}

	var wg sync.WaitGroup
	for range 10 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := c.ValidateDeposited(context.Background(), "7"); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	first := calls.Load()
	if first > 6 { // SubAccounts once, then ownerOf and the record: twice at most if the goroutines straddle the first
		t.Fatalf("ten orders made %d custody reads", first)
	}
	if err := c.ValidateDeposited(context.Background(), "7"); err != nil || calls.Load() != first {
		t.Fatalf("a check inside custodyConfirmedTTL went to the chain (%d calls)", calls.Load())
	}
	clock = clock.Add(custodyConfirmedTTL)
	if err := c.ValidateDeposited(context.Background(), "7"); err != nil || calls.Load() != first+2 {
		t.Fatalf("after custodyConfirmedTTL custody was not read again (%d calls, was %d)", calls.Load(), first)
	}
}

func TestARefusalIsNeverKept(t *testing.T) {
	matching := "0x" + strings.Repeat("ab", 20)
	rpc, calls := custodyStub(matching)
	defer rpc.Close()
	c := &chainCustodyChecker{rpcURL: rpc.URL, matchingAddress: matching, httpClient: rpc.Client()}
	for range 2 {
		if err := c.ValidateDeposited(context.Background(), "8"); err == nil || !strings.Contains(err.Error(), "not deposited") {
			t.Fatalf("subaccount 8 is not in Matching: %v", err)
		}
	}
	if calls.Load() != 3 { // SubAccounts once, then ownerOf each time
		t.Fatalf("a refusal was answered from cache (%d calls)", calls.Load())
	}
}
