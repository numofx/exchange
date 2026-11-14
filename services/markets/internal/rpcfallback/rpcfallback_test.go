package rpcfallback

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

// hosts answers each host with its status and records what each was sent.
type hosts struct {
	status map[string]int
	got    []string
}

func (h *hosts) RoundTrip(req *http.Request) (*http.Response, error) {
	b, _ := io.ReadAll(req.Body)
	h.got = append(h.got, req.URL.String()+" "+string(b))
	return &http.Response{StatusCode: h.status[req.URL.Host], Body: io.NopCloser(strings.NewReader("{}")), Request: req}, nil
}

func post(t *testing.T, rt http.RoundTripper, url, body string) int {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, url, strings.NewReader(body))
	resp, err := rt.RoundTrip(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode
}

const call = `{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[]}`

func TestARateLimitedCallGoesToTheFallback(t *testing.T) {
	next := &hosts{status: map[string]int{"mainnet.base.org": 429, "base-mainnet.g.alchemy.com": 200}}
	rt, err := New(next, "https://mainnet.base.org", "https://base-mainnet.g.alchemy.com/v2/key")
	if err != nil {
		t.Fatal(err)
	}
	if got := post(t, rt, "https://mainnet.base.org", call); got != 200 {
		t.Fatalf("status %d, want the fallback's 200", got)
	}
	want := []string{"https://mainnet.base.org " + call, "https://base-mainnet.g.alchemy.com/v2/key " + call}
	if len(next.got) != 2 || next.got[0] != want[0] || next.got[1] != want[1] {
		t.Fatalf("sent %q, want %q", next.got, want)
	}
}

func TestAnAnsweredCallAndOtherHostsNeverReachTheFallback(t *testing.T) {
	next := &hosts{status: map[string]int{"mainnet.base.org": 200, "api.numofx.com": 429}}
	rt, _ := New(next, "https://mainnet.base.org", "https://base-mainnet.g.alchemy.com/v2/key")
	post(t, rt, "https://mainnet.base.org", call)
	if got := post(t, rt, "https://api.numofx.com/orders", `{"market":"cNGN-USDC"}`); got != 429 {
		t.Fatalf("an API 429 must come back as it is, got %d", got)
	}
	if len(next.got) != 2 || strings.Contains(strings.Join(next.got, " "), "alchemy") {
		t.Fatalf("sent %q", next.got)
	}
}
