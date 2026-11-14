// Package rpcfallback sends a JSON-RPC request the primary endpoint rate-limits (HTTP 429) on to a fallback
// endpoint. The primary is the free public Base RPC, which allows 25 requests a second per source IP, an IP every
// ECS task shares through the NAT; the fallback is a keyed, billed endpoint. So the billed endpoint is paid only for
// the requests the free one turns away. It exists because the options maker, reading ten strikes at once at
// startup, was refused there and exited in a loop, and markets-service then could not read its custody (2026-11-14).
// The same package is in market-maker (internal/rpcfallback).
package rpcfallback

import (
	"bytes"
	"io"
	"net/http"
	"net/url"
)

// maxBody is the largest request body held for a retry; a JSON-RPC request is far smaller.
const maxBody = 1 << 20

// Transport is an http.RoundTripper that retries a primary-host POST refused with 429 against the fallback URL.
type Transport struct {
	next     http.RoundTripper
	primary  string
	fallback *url.URL
}

// New is a Transport over `next`. Requests to any host other than primaryURL's go through untouched.
func New(next http.RoundTripper, primaryURL, fallbackURL string) (*Transport, error) {
	primary, err := url.Parse(primaryURL)
	if err != nil {
		return nil, err
	}
	fallback, err := url.Parse(fallbackURL)
	if err != nil {
		return nil, err
	}
	return &Transport{next: next, primary: primary.Host, fallback: fallback}, nil
}

// Install puts a Transport in front of http.DefaultTransport. With no fallback URL it does nothing.
func Install(primaryURL, fallbackURL string) error {
	if fallbackURL == "" {
		return nil
	}
	t, err := New(http.DefaultTransport, primaryURL, fallbackURL)
	if err != nil {
		return err
	}
	http.DefaultTransport = t
	return nil
}

func (t *Transport) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.Method != http.MethodPost || req.URL.Host != t.primary || req.Body == nil || req.ContentLength > maxBody {
		return t.next.RoundTrip(req)
	}
	body, err := io.ReadAll(io.LimitReader(req.Body, maxBody+1))
	_ = req.Body.Close()
	if err != nil {
		return nil, err
	}
	first := withBody(req, req.URL, body)
	resp, err := t.next.RoundTrip(first)
	if err != nil || resp.StatusCode != http.StatusTooManyRequests || len(body) > maxBody {
		return resp, err
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
	return t.next.RoundTrip(withBody(req, t.fallback, body))
}

func withBody(req *http.Request, to *url.URL, body []byte) *http.Request {
	out := req.Clone(req.Context())
	out.URL = to
	out.Host = to.Host
	out.Body = io.NopCloser(bytes.NewReader(body))
	out.ContentLength = int64(len(body))
	out.GetBody = func() (io.ReadCloser, error) { return io.NopCloser(bytes.NewReader(body)), nil }
	return out
}
