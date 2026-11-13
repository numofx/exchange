// Package rpccount counts the JSON-RPC calls a process makes, by endpoint host, method and HTTP status, and logs the
// counts once a window. It wraps http.DefaultTransport, which every RPC client in the process reaches (ethclient and
// the hand-rolled eth_call clients alike), and counts only POSTs whose body is JSON-RPC, so API traffic is left out.
//
// It exists because the venue's RPC plan ran out on 2026-11-12 with nothing saying which service or call used it.
// A batch counts each call in it: providers bill per call, not per HTTP request.
package rpccount

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// maxBody is the largest request body inspected for a method. A JSON-RPC request is far smaller; a larger body is
// passed through uncounted rather than held in memory.
const maxBody = 1 << 20

type key struct {
	host   string
	method string
	status string
}

// Counter is an http.RoundTripper that counts the JSON-RPC calls passing through it.
type Counter struct {
	next http.RoundTripper

	mu     sync.Mutex
	counts map[key]int
}

// New is a Counter in front of `next`.
func New(next http.RoundTripper) *Counter {
	return &Counter{next: next, counts: map[key]int{}}
}

// Install puts a Counter in front of http.DefaultTransport and logs its counts every `every` until ctx ends, with a
// final flush then. Call it once, at the start of main, before any RPC client is made.
func Install(ctx context.Context, logger *slog.Logger, every time.Duration) *Counter {
	counter := New(http.DefaultTransport)
	http.DefaultTransport = counter
	go counter.report(ctx, logger, every)
	return counter
}

func (c *Counter) RoundTrip(req *http.Request) (*http.Response, error) {
	methods, req := jsonRPCMethods(req)
	resp, err := c.next.RoundTrip(req)
	if len(methods) == 0 {
		return resp, err
	}
	status := "error"
	if err == nil {
		status = strconv.Itoa(resp.StatusCode)
	}
	c.mu.Lock()
	for _, method := range methods {
		c.counts[key{host: req.URL.Host, method: method, status: status}]++
	}
	c.mu.Unlock()
	return resp, err
}

// jsonRPCMethods is the methods of a JSON-RPC request, one per call, and the request to send in its place (its body
// read here and replayed). A request that is not JSON-RPC has no methods and goes out as it came.
func jsonRPCMethods(req *http.Request) ([]string, *http.Request) {
	if req.Method != http.MethodPost || req.Body == nil || req.Body == http.NoBody {
		return nil, req
	}
	if req.ContentLength > maxBody {
		return nil, req
	}
	body, err := io.ReadAll(io.LimitReader(req.Body, maxBody+1))
	_ = req.Body.Close()
	replay := req.Clone(req.Context())
	replay.Body = io.NopCloser(bytes.NewReader(body))
	replay.GetBody = func() (io.ReadCloser, error) { return io.NopCloser(bytes.NewReader(body)), nil }
	if err != nil || len(body) > maxBody {
		return nil, replay
	}
	return parseMethods(body), replay
}

func parseMethods(body []byte) []string {
	type call struct {
		JSONRPC string `json:"jsonrpc"`
		Method  string `json:"method"`
	}
	trimmed := bytes.TrimSpace(body)
	var calls []call
	switch {
	case bytes.HasPrefix(trimmed, []byte("[")):
		if json.Unmarshal(trimmed, &calls) != nil {
			return nil
		}
	case bytes.HasPrefix(trimmed, []byte("{")):
		var one call
		if json.Unmarshal(trimmed, &one) != nil {
			return nil
		}
		calls = []call{one}
	default:
		return nil
	}
	methods := make([]string, 0, len(calls))
	for _, c := range calls {
		if c.JSONRPC == "" || c.Method == "" {
			return nil
		}
		methods = append(methods, c.Method)
	}
	return methods
}

// Window is one host's counts over a window, as logged.
type Window struct {
	Host     string
	Total    int
	ByMethod string // "eth_call:120,eth_blockNumber:30", largest first
	ByStatus string // "200:148,429:2"
}

// Drain returns the counts since the last drain, one entry per host, and starts a new window.
func (c *Counter) Drain() []Window {
	c.mu.Lock()
	counts := c.counts
	c.counts = map[key]int{}
	c.mu.Unlock()

	type tally struct {
		total    int
		byMethod map[string]int
		byStatus map[string]int
	}
	hosts := map[string]*tally{}
	for k, n := range counts {
		t := hosts[k.host]
		if t == nil {
			t = &tally{byMethod: map[string]int{}, byStatus: map[string]int{}}
			hosts[k.host] = t
		}
		t.total += n
		t.byMethod[k.method] += n
		t.byStatus[k.status] += n
	}
	out := make([]Window, 0, len(hosts))
	for host, t := range hosts {
		out = append(out, Window{Host: host, Total: t.total, ByMethod: joinCounts(t.byMethod), ByStatus: joinCounts(t.byStatus)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Total > out[j].Total })
	return out
}

func joinCounts(counts map[string]int) string {
	names := make([]string, 0, len(counts))
	for name := range counts {
		names = append(names, name)
	}
	sort.Slice(names, func(i, j int) bool {
		if counts[names[i]] != counts[names[j]] {
			return counts[names[i]] > counts[names[j]]
		}
		return names[i] < names[j]
	})
	parts := make([]string, len(names))
	for i, name := range names {
		parts[i] = fmt.Sprintf("%s:%d", name, counts[name])
	}
	return strings.Join(parts, ",")
}

func (c *Counter) report(ctx context.Context, logger *slog.Logger, every time.Duration) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			c.log(logger, every)
			return
		case <-ticker.C:
			c.log(logger, every)
		}
	}
}

func (c *Counter) log(logger *slog.Logger, every time.Duration) {
	for _, w := range c.Drain() {
		logger.Info("rpc_calls", "host", w.Host, "window_s", int(every.Seconds()), "total", w.Total,
			"by_method", w.ByMethod, "by_status", w.ByStatus)
	}
}
