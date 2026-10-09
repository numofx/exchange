package matching

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"
)

// settlementAlerter posts settlement failures to the ops webhook (ALERT_WEBHOOK_URL, the same channel as the
// settlement canary and the deposit pause).
//
// A submission that fails is retried on a backoff and may well succeed, but on 2026-10-09 eight fills failed to
// submit and were never retried into a settlement, and nothing but a log line said so. So:
//
//   - the first failure after a clean run posts NUMO SETTLEMENT FAILING at once; while failures continue it posts
//     again at most every repeatEvery, with the count; the next settlement that succeeds posts NUMO SETTLEMENT
//     RECOVERED with the total.
//   - an outcome that needs a person -- broadcast but unconfirmed (orders left reserved), or settled on chain but not
//     recorded -- posts every time, immediately: each one is a pair of orders someone has to resolve by hand.
//
// Posts never block matching: each runs on its own goroutine with a timeout.
type settlementAlerter struct {
	url         string
	repeatEvery time.Duration
	now         func() time.Time
	post        func(ctx context.Context, url, text string) error

	mu          sync.Mutex
	failing     bool
	failures    int
	since       time.Time
	lastAlertAt time.Time
}

func newSettlementAlerter(url string) *settlementAlerter {
	url = strings.TrimSpace(url)
	if url == "" {
		slog.Warn("settlement_alerts_disabled", "reason", "ALERT_WEBHOOK_URL is not set")
	}
	return &settlementAlerter{url: url, repeatEvery: 15 * time.Minute, now: time.Now, post: postAlert}
}

// Failed records a submission that did not settle and will be retried.
func (a *settlementAlerter) Failed(market, reason, takerOrderID, makerOrderID string, cause error) {
	if a == nil {
		return
	}
	a.mu.Lock()
	now := a.now()
	a.failures++
	var text string
	switch {
	case !a.failing:
		a.failing, a.since, a.lastAlertAt = true, now, now
		text = fmt.Sprintf("NUMO SETTLEMENT FAILING\n%s %s: %s\ntaker %s, maker %s\nThe pair is released and retried; check the executor.",
			market, reason, short(cause), takerOrderID, makerOrderID)
	case now.Sub(a.lastAlertAt) >= a.repeatEvery:
		a.lastAlertAt = now
		text = fmt.Sprintf("NUMO SETTLEMENT STILL FAILING\n%d failures since %s; latest %s %s: %s",
			a.failures, a.since.UTC().Format("15:04:05Z"), market, reason, short(cause))
	}
	a.mu.Unlock()
	a.send(text)
}

// Settled records a settlement that went through; it closes a failing run.
func (a *settlementAlerter) Settled() {
	if a == nil {
		return
	}
	a.mu.Lock()
	var text string
	if a.failing {
		text = fmt.Sprintf("NUMO SETTLEMENT RECOVERED\nSettling again after %d failures since %s.", a.failures, a.since.UTC().Format("15:04:05Z"))
	}
	a.failing, a.failures = false, 0
	a.mu.Unlock()
	a.send(text)
}

// NeedsResolution posts an outcome that only a person can resolve, every time.
func (a *settlementAlerter) NeedsResolution(what, market, takerOrderID, makerOrderID string, cause error) {
	if a == nil {
		return
	}
	a.send(fmt.Sprintf("NUMO SETTLEMENT NEEDS RESOLUTION\n%s\n%s taker %s, maker %s: %s", what, market, takerOrderID, makerOrderID, short(cause)))
}

func (a *settlementAlerter) send(text string) {
	if text == "" || a.url == "" {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := a.post(ctx, a.url, text); err != nil {
			slog.Error("settlement_alert_failed", "error", err)
		}
	}()
}

func short(err error) string {
	if err == nil {
		return "no error detail"
	}
	s := err.Error()
	if i := strings.Index(s, "\n"); i > 0 {
		s = s[:i]
	}
	if len(s) > 300 {
		s = s[:300] + "..."
	}
	return s
}

func postAlert(ctx context.Context, url, text string) error {
	body, _ := json.Marshal(map[string]string{"text": text, "content": text})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("webhook returned %d", resp.StatusCode)
	}
	return nil
}
