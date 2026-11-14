package options

import (
	"context"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// managerStub answers every eth_call with the engine's address, after `refuse` 429s, and counts the calls.
func managerStub(refuse int32) (*httptest.Server, *atomic.Int32) {
	var calls atomic.Int32
	engine := strings.Repeat("e2", 20)
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) <= refuse {
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		fmt.Fprintf(w, `{"jsonrpc":"2.0","id":1,"result":"0x%s%s"}`, strings.Repeat("0", 24), engine)
	})), &calls
}

func TestAManagerIsReadOnceForMany(t *testing.T) {
	rpc, calls := managerStub(0)
	defer rpc.Close()
	r := stubReader(rpc.URL)
	clock := time.Unix(1_800_000_000, 0)
	r.now = func() time.Time { return clock }
	account := big.NewInt(42)

	var wg sync.WaitGroup
	for range 10 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if m, err := r.ManagerOf(context.Background(), account); err != nil || m != "0x"+strings.Repeat("e2", 20) {
				t.Errorf("manager %q, %v", m, err)
			}
		}()
	}
	wg.Wait()
	first := calls.Load()
	if first > 2*10/5 { // the ledger once and the manager once, or a few if the goroutines straddle the first read
		t.Fatalf("ten orders made %d reads", first)
	}
	if _, err := r.ManagerOf(context.Background(), account); err != nil || calls.Load() != first {
		t.Fatalf("a read inside managerTTL went to the chain (%d calls)", calls.Load())
	}
	clock = clock.Add(managerTTL)
	if _, err := r.ManagerOf(context.Background(), account); err != nil || calls.Load() != first+1 {
		t.Fatalf("after managerTTL the manager was not read again (%d calls, was %d)", calls.Load(), first)
	}
}

func TestAFailedManagerReadIsNotKept(t *testing.T) {
	rpc, calls := managerStub(1)
	defer rpc.Close()
	r := stubReader(rpc.URL)
	if _, err := r.ManagerOf(context.Background(), big.NewInt(42)); err == nil {
		t.Fatal("a 429 read as a manager")
	}
	if m, err := r.ManagerOf(context.Background(), big.NewInt(42)); err != nil || m == "" {
		t.Fatalf("the read after a failure did not go to the chain: %q, %v (%d calls)", m, err, calls.Load())
	}
}
