package api

import (
	"bytes"
	"context"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"
)

// The /v1/integrations endpoints are for third parties that poll, and every uncached request reads
// the same Postgres the matcher and trading UI depend on (including the expiry UPDATE ListBook and
// BestBidAndAsk run first). This cache puts a ceiling on that: at most one computation per distinct
// request per TTL, however many clients poll and however fast.
//
// Two properties make the ceiling real rather than nominal:
//   - Concurrent misses for one key share a single computation (singleflight), so a burst arriving
//     as an entry expires does not become a burst of queries.
//   - The key is built only from the parameters the endpoint reads. Any other query string is
//     ignored, so appending ?nonce=... cannot be used to step around the cache.

const (
	integrationCacheTTL = 5 * time.Second
	// integrationCacheMaxEntries bounds memory. before_trade_id makes the key space open-ended; when
	// the map is full, expired entries are swept, and if it is still full the response is served
	// uncached (still deduplicated by singleflight) rather than evicting something fresh.
	integrationCacheMaxEntries = 1024
	// integrationComputeTimeout bounds a shared computation. It runs detached from the first
	// caller's context so that one client disconnecting does not fail every request waiting on it.
	integrationComputeTimeout = 10 * time.Second
)

type integrationCache struct {
	ttl        time.Duration
	now        func() time.Time
	maxEntries int

	mu      sync.Mutex
	entries map[string]cachedIntegrationResponse
	flight  singleflight.Group
}

type cachedIntegrationResponse struct {
	status      int
	contentType string
	body        []byte
	expires     time.Time
}

func newIntegrationCache(ttl time.Duration, now func() time.Time) *integrationCache {
	return &integrationCache{
		ttl:        ttl,
		now:        now,
		maxEntries: integrationCacheMaxEntries,
		entries:    make(map[string]cachedIntegrationResponse),
	}
}

// wrap serves handler through the cache, keyed on the request path and the named query parameters.
// Only 200 responses are stored; errors are recomputed on the next request.
func (c *integrationCache) wrap(handler http.HandlerFunc, params ...string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		key := integrationCacheKey(r, params)

		if response, ok := c.lookup(key); ok {
			c.write(w, response)
			return
		}

		result, _, _ := c.flight.Do(key, func() (any, error) {
			// Another caller may have stored the entry between our lookup and joining the flight.
			if response, ok := c.lookup(key); ok {
				return response, nil
			}
			ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), integrationComputeTimeout)
			defer cancel()

			recorder := &capturingResponseWriter{header: http.Header{}, status: http.StatusOK}
			handler(recorder, r.WithContext(ctx))

			response := cachedIntegrationResponse{
				status:      recorder.status,
				contentType: recorder.header.Get("Content-Type"),
				body:        recorder.body.Bytes(),
				expires:     c.now().Add(c.ttl),
			}
			if response.status == http.StatusOK {
				c.store(key, response)
			}
			return response, nil
		})
		c.write(w, result.(cachedIntegrationResponse))
	}
}

func integrationCacheKey(r *http.Request, params []string) string {
	query := r.URL.Query()
	canonical := url.Values{}
	for _, name := range params {
		if value := strings.TrimSpace(query.Get(name)); value != "" {
			canonical.Set(name, value)
		}
	}
	return r.URL.Path + "?" + canonical.Encode()
}

func (c *integrationCache) lookup(key string) (cachedIntegrationResponse, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	response, ok := c.entries[key]
	if !ok || !c.now().Before(response.expires) {
		return cachedIntegrationResponse{}, false
	}
	return response, true
}

func (c *integrationCache) store(key string, response cachedIntegrationResponse) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.entries) >= c.maxEntries {
		now := c.now()
		for existing, entry := range c.entries {
			if !now.Before(entry.expires) {
				delete(c.entries, existing)
			}
		}
		if len(c.entries) >= c.maxEntries {
			return
		}
	}
	c.entries[key] = response
}

func (c *integrationCache) write(w http.ResponseWriter, response cachedIntegrationResponse) {
	if response.contentType != "" {
		w.Header().Set("Content-Type", response.contentType)
	}
	if response.status == http.StatusOK {
		// Lets a CDN or a well-behaved client hold the response as long as this process does.
		w.Header().Set("Cache-Control", "public, max-age="+strconv.Itoa(int(c.ttl/time.Second)))
	}
	w.WriteHeader(response.status)
	_, _ = w.Write(response.body)
}

type capturingResponseWriter struct {
	header      http.Header
	status      int
	wroteHeader bool
	body        bytes.Buffer
}

func (w *capturingResponseWriter) Header() http.Header { return w.header }

func (w *capturingResponseWriter) WriteHeader(status int) {
	if w.wroteHeader {
		return
	}
	w.status, w.wroteHeader = status, true
}

func (w *capturingResponseWriter) Write(p []byte) (int, error) {
	w.wroteHeader = true
	return w.body.Write(p)
}
