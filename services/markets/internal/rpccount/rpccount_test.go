package rpccount

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

// echo is the next transport: it records the body it was sent and answers with `status`.
type echo struct {
	status int
	got    []string
}

func (e *echo) RoundTrip(req *http.Request) (*http.Response, error) {
	body := ""
	if req.Body != nil {
		b, _ := io.ReadAll(req.Body)
		body = string(b)
	}
	e.got = append(e.got, body)
	return &http.Response{StatusCode: e.status, Body: io.NopCloser(strings.NewReader("{}")), Request: req}, nil
}

func post(t *testing.T, c *Counter, url, body string) {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, url, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.RoundTrip(req); err != nil {
		t.Fatal(err)
	}
}

func TestCountsCallsByHostMethodAndStatus(t *testing.T) {
	next := &echo{status: 200}
	c := New(next)
	call := `{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[]}`
	post(t, c, "https://base-mainnet.g.alchemy.com/v2/secret-key", call)
	post(t, c, "https://base-mainnet.g.alchemy.com/v2/secret-key", call)
	post(t, c, "https://base-mainnet.g.alchemy.com/v2/secret-key",
		`[{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber"},{"jsonrpc":"2.0","id":2,"method":"eth_call"}]`)
	next.status = 429
	post(t, c, "https://mainnet.base.org", call)

	// The body reached the RPC untouched.
	if next.got[0] != call {
		t.Fatalf("forwarded body %q, want %q", next.got[0], call)
	}
	windows := c.Drain()
	if len(windows) != 2 {
		t.Fatalf("windows = %+v, want 2 hosts", windows)
	}
	alchemy := windows[0]
	if alchemy.Host != "base-mainnet.g.alchemy.com" || alchemy.Total != 4 ||
		alchemy.ByMethod != "eth_call:3,eth_blockNumber:1" || alchemy.ByStatus != "200:4" {
		t.Fatalf("alchemy window %+v", alchemy)
	}
	if strings.Contains(alchemy.Host, "secret") {
		t.Fatal("the key in the URL path must never be logged")
	}
	public := windows[1]
	if public.Host != "mainnet.base.org" || public.Total != 1 || public.ByStatus != "429:1" {
		t.Fatalf("public window %+v", public)
	}
	if again := c.Drain(); len(again) != 0 {
		t.Fatalf("a drain starts a new window, got %+v", again)
	}
}

func TestIgnoresTrafficThatIsNotJSONRPC(t *testing.T) {
	next := &echo{status: 200}
	c := New(next)
	post(t, c, "http://markets-service:8080/orders", `{"market":"cNGN-USDC","side":"buy"}`)
	post(t, c, "http://markets-service:8080/orders", `not json`)
	req, _ := http.NewRequest(http.MethodGet, "http://markets-service:8080/markets", nil)
	if _, err := c.RoundTrip(req); err != nil {
		t.Fatal(err)
	}
	if windows := c.Drain(); len(windows) != 0 {
		t.Fatalf("counted non-RPC traffic: %+v", windows)
	}
	if next.got[0] != `{"market":"cNGN-USDC","side":"buy"}` {
		t.Fatalf("an API body must pass through untouched, got %q", next.got[0])
	}
}
