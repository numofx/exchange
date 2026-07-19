package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/numofx/matching-backend/internal/events"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
	"github.com/numofx/matching-backend/internal/wsauth"
)

const (
	wsWriteTimeout   = 10 * time.Second
	wsPingInterval   = 15 * time.Second
	wsReadLimit      = 1 << 16 // 64 KiB
	wsSnapshotBook   = 50
	wsSnapshotTrades = 50
	wsSnapshotOrders = 200
	wsReplayLimit    = 1000
)

// wsIn is a client control frame. Auth fields are embedded (flattened into the JSON).
type wsIn struct {
	Op       string `json:"op"` // auth | subscribe | unsubscribe | ping
	Channel  string `json:"channel"`
	Market   string `json:"market"`
	SinceSeq int64  `json:"since_seq"`
	wsauth.AuthFrame
}

// wsOut is a server frame. Every book/trades/orders frame carries the seq it reflects, so the
// client can dedup against a snapshot boundary and detect gaps.
type wsOut struct {
	Type    string `json:"type"` // snapshot | update | pong | ack | error
	Channel string `json:"channel,omitempty"`
	Market  string `json:"market,omitempty"`
	Seq     int64  `json:"seq,omitempty"`
	Data    any    `json:"data,omitempty"`
	Code    string `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
}

// wsConn multiplexes many channel subscriptions over one socket. coder/websocket allows one
// concurrent reader and one concurrent writer, so all reads happen in readLoop and all writes
// are funnelled through out -> writeLoop.
type wsConn struct {
	srv    *Server
	conn   *websocket.Conn
	out    chan wsOut
	cancel context.CancelFunc

	mu    sync.Mutex
	owner string // authenticated address; empty until a successful auth frame
	subs  map[string]*wsSubscription
	once  sync.Once
}

type wsSubscription struct {
	sub    *events.Sub
	cancel context.CancelFunc // cancels this subscription's forwarder (explicit unsubscribe)
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{OriginPatterns: s.cfg.WSAllowedOrigins})
	if err != nil {
		slog.Debug("ws accept failed", "error", err)
		return
	}
	conn.SetReadLimit(wsReadLimit)

	ctx, cancel := context.WithCancel(r.Context())
	c := &wsConn{
		srv:    s,
		conn:   conn,
		out:    make(chan wsOut, s.cfg.EventsSubBuffer),
		cancel: cancel,
		subs:   make(map[string]*wsSubscription),
	}
	defer c.shutdown()

	go c.writeLoop(ctx)
	c.readLoop(ctx)
}

func (c *wsConn) writeLoop(ctx context.Context) {
	ping := time.NewTicker(wsPingInterval)
	defer ping.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case f := <-c.out:
			wctx, cancel := context.WithTimeout(ctx, wsWriteTimeout)
			b, err := json.Marshal(f)
			if err == nil {
				err = c.conn.Write(wctx, websocket.MessageText, b)
			}
			cancel()
			if err != nil {
				c.drop(websocket.StatusInternalError, "write failed")
				return
			}
		case <-ping.C:
			pctx, cancel := context.WithTimeout(ctx, wsWriteTimeout)
			err := c.conn.Ping(pctx)
			cancel()
			if err != nil {
				c.drop(websocket.StatusGoingAway, "ping timeout")
				return
			}
		}
	}
}

func (c *wsConn) readLoop(ctx context.Context) {
	for {
		typ, data, err := c.conn.Read(ctx)
		if err != nil {
			c.cancel() // remote closed or ctx done
			return
		}
		if typ != websocket.MessageText {
			continue
		}
		var in wsIn
		if err := json.Unmarshal(data, &in); err != nil {
			c.send(wsOut{Type: "error", Code: "bad_json", Message: "invalid frame"})
			continue
		}
		switch strings.ToLower(strings.TrimSpace(in.Op)) {
		case "auth":
			c.handleAuth(in)
		case "subscribe":
			c.handleSubscribe(ctx, in)
		case "unsubscribe":
			c.handleUnsubscribe(in)
		case "ping":
			c.send(wsOut{Type: "pong"})
		default:
			c.send(wsOut{Type: "error", Code: "bad_op", Message: "unknown op"})
		}
	}
}

func (c *wsConn) handleAuth(in wsIn) {
	owner, err := c.srv.wsAuth.Verify(in.AuthFrame, time.Now())
	if err != nil {
		c.send(wsOut{Type: "error", Code: "auth_failed", Message: err.Error()})
		return
	}
	c.mu.Lock()
	c.owner = owner
	c.mu.Unlock()
	c.send(wsOut{Type: "ack", Message: "authenticated"})
}

func (c *wsConn) handleSubscribe(ctx context.Context, in wsIn) {
	channel := strings.ToLower(strings.TrimSpace(in.Channel))

	filter, meta, ok := c.buildFilter(channel, in.Market)
	if !ok {
		return // buildFilter already sent the error frame
	}

	key := channel + "|" + strings.TrimSpace(in.Market)
	c.mu.Lock()
	if _, exists := c.subs[key]; exists {
		c.mu.Unlock()
		return // idempotent
	}
	c.mu.Unlock()

	sub, valid := c.srv.hub.Subscribe(filter) // registration begins buffering immediately
	if !valid {
		c.send(errFrame(channel, in.Market, "bad_subscribe", "invalid filter"))
		return
	}

	// Register the forwarder under a child context so an explicit unsubscribe cancels it
	// quietly (vs a hub-side drop, which arrives via sub.Done()).
	subCtx, subCancel := context.WithCancel(ctx)
	c.mu.Lock()
	c.subs[key] = &wsSubscription{sub: sub, cancel: subCancel}
	c.mu.Unlock()

	var boundary int64
	if in.SinceSeq > 0 {
		replayed, ok := c.tryResume(ctx, filter, in.SinceSeq, channel, in.Market)
		if ok {
			boundary = replayed
		} else {
			b, err := c.sendSnapshot(ctx, channel, meta, in.Market)
			if err != nil {
				c.teardownSub(key, "snapshot_failed", in.Market, channel)
				return
			}
			boundary = b
		}
	} else {
		b, err := c.sendSnapshot(ctx, channel, meta, in.Market)
		if err != nil {
			c.teardownSub(key, "snapshot_failed", in.Market, channel)
			return
		}
		boundary = b
	}

	go c.forward(subCtx, sub, boundary, channel, in.Market, key)
}

// buildFilter validates the channel + market and returns the Hub filter and instrument meta.
// It sends the appropriate error frame and returns ok=false on any problem.
func (c *wsConn) buildFilter(channel, market string) (events.Filter, instruments.Metadata, bool) {
	switch channel {
	case events.ChannelBook, events.ChannelTrades:
		meta, ok := c.srv.resolveMarketSymbol(market)
		if !ok {
			c.send(errFrame(channel, market, "unknown_market", "no such market"))
			return events.Filter{}, instruments.Metadata{}, false
		}
		return events.Filter{Channel: channel, Market: marketKeyOf(meta)}, meta, true
	case events.ChannelOrders:
		c.mu.Lock()
		owner := c.owner
		c.mu.Unlock()
		if owner == "" {
			c.send(errFrame(channel, market, "auth_required", "authenticate before subscribing to orders"))
			return events.Filter{}, instruments.Metadata{}, false
		}
		f := events.Filter{Channel: channel, Owner: owner}
		var meta instruments.Metadata
		if strings.TrimSpace(market) != "" { // optional scoping to one market
			m, ok := c.srv.resolveMarketSymbol(market)
			if !ok {
				c.send(errFrame(channel, market, "unknown_market", "no such market"))
				return events.Filter{}, instruments.Metadata{}, false
			}
			meta, f.Market = m, marketKeyOf(m)
		}
		return f, meta, true
	default:
		c.send(errFrame(channel, market, "bad_channel", "unknown channel"))
		return events.Filter{}, instruments.Metadata{}, false
	}
}

// sendSnapshot emits one snapshot frame and returns the consistent boundary seq (data + seq
// read in one repeatable-read txn). Live deltas with seq <= boundary are dropped by forward.
func (c *wsConn) sendSnapshot(ctx context.Context, channel string, meta instruments.Metadata, market string) (int64, error) {
	switch channel {
	case events.ChannelBook:
		bids, asks, seq, err := c.srv.orders.SnapshotBook(ctx, meta.AssetAddress, meta.SubID, wsSnapshotBook)
		if err != nil {
			return 0, err
		}
		c.send(wsOut{Type: "snapshot", Channel: channel, Market: market, Seq: seq, Data: bookResponse{
			MarketPresentation: c.srv.presentMarket(ctx, meta),
			Bids:               presentOrders(bids, meta),
			Asks:               presentOrders(asks, meta),
		}})
		return seq, nil
	case events.ChannelTrades:
		trades, seq, err := c.srv.orders.SnapshotTrades(ctx, meta.AssetAddress, meta.SubID, wsSnapshotTrades)
		if err != nil {
			return 0, err
		}
		c.send(wsOut{Type: "snapshot", Channel: channel, Market: market, Seq: seq, Data: presentTrades(trades, meta)})
		return seq, nil
	case events.ChannelOrders:
		c.mu.Lock()
		owner := c.owner
		c.mu.Unlock()
		ords, seq, err := c.srv.orders.SnapshotOpenOrdersByOwner(ctx, owner, wsSnapshotOrders)
		if err != nil {
			return 0, err
		}
		c.send(wsOut{Type: "snapshot", Channel: channel, Market: market, Seq: seq, Data: c.srv.presentOwnerOrders(ords)})
		return seq, nil
	}
	return 0, nil
}

// tryResume replays log rows after sinceSeq for a reconnecting client. Returns ok=false (so
// the caller falls back to a fresh snapshot) if the resume point is older than what's retained.
func (c *wsConn) tryResume(ctx context.Context, filter events.Filter, sinceSeq int64, channel, market string) (int64, bool) {
	oldest, err := c.srv.hub.OldestSeq(ctx)
	if err != nil {
		return 0, false
	}
	if oldest > 0 && sinceSeq < oldest-1 {
		c.send(errFrame(channel, market, "resume_too_old", "snapshot follows"))
		return 0, false
	}
	evs, err := c.srv.hub.Since(ctx, filter, sinceSeq, wsReplayLimit)
	if err != nil {
		return 0, false
	}
	boundary := sinceSeq
	for _, e := range evs {
		c.send(wsOut{Type: "update", Channel: channel, Market: market, Seq: e.Seq, Data: e.Payload})
		boundary = e.Seq
	}
	return boundary, true
}

// forward relays live deltas for one subscription, dropping anything already covered by the
// snapshot/replay boundary. ctx cancel = explicit unsubscribe (quiet); sub.Done() = hub-side
// drop (tell the client to resume).
func (c *wsConn) forward(ctx context.Context, sub *events.Sub, boundary int64, channel, market, key string) {
	defer c.detachSub(key, sub)
	for {
		select {
		case <-ctx.Done():
			return
		case <-sub.Done():
			c.send(errFrame(channel, market, "stream_reset", "resubscribe with since_seq"))
			return
		case e := <-sub.Events():
			if e.Seq <= boundary {
				continue
			}
			if !c.send(wsOut{Type: "update", Channel: channel, Market: market, Seq: e.Seq, Data: e.Payload}) {
				return
			}
		}
	}
}

func (c *wsConn) handleUnsubscribe(in wsIn) {
	key := strings.ToLower(strings.TrimSpace(in.Channel)) + "|" + strings.TrimSpace(in.Market)
	c.mu.Lock()
	entry := c.subs[key]
	c.mu.Unlock()
	if entry != nil {
		entry.cancel() // forwarder exits via ctx.Done(); its defer detaches + unsubscribes
		c.send(wsOut{Type: "ack", Channel: in.Channel, Market: in.Market, Message: "unsubscribed"})
	}
}

func (c *wsConn) teardownSub(key, code, market, channel string) {
	c.mu.Lock()
	entry := c.subs[key]
	delete(c.subs, key)
	c.mu.Unlock()
	if entry != nil {
		c.srv.hub.Unsubscribe(entry.sub)
		entry.cancel()
	}
	c.send(errFrame(channel, market, code, "could not load snapshot"))
}

// detachSub removes a subscription mapping and unsubscribes from the Hub (forwarder defer).
func (c *wsConn) detachSub(key string, sub *events.Sub) {
	c.mu.Lock()
	if entry, ok := c.subs[key]; ok && entry.sub == sub {
		delete(c.subs, key)
	}
	c.mu.Unlock()
	c.srv.hub.Unsubscribe(sub)
}

// send enqueues a frame. A full buffer means a slow consumer: drop the whole connection (the
// client reconnects and resumes via since_seq) rather than stalling the fan-out.
func (c *wsConn) send(f wsOut) bool {
	select {
	case c.out <- f:
		return true
	default:
		c.drop(websocket.StatusTryAgainLater, "slow consumer")
		return false
	}
}

func (c *wsConn) drop(code websocket.StatusCode, reason string) {
	c.once.Do(func() {
		c.cancel()
		_ = c.conn.Close(code, reason)
	})
}

func (c *wsConn) shutdown() {
	c.cancel()
	c.mu.Lock()
	subs := c.subs
	c.subs = make(map[string]*wsSubscription)
	c.mu.Unlock()
	for _, entry := range subs {
		c.srv.hub.Unsubscribe(entry.sub)
	}
	c.once.Do(func() { _ = c.conn.Close(websocket.StatusNormalClosure, "bye") })
}

func errFrame(channel, market, code, msg string) wsOut {
	return wsOut{Type: "error", Channel: channel, Market: market, Code: code, Message: msg}
}

// resolveMarketSymbol maps a client market identifier (instrument symbol, or "asset:sub_id")
// to its instrument metadata.
func (s *Server) resolveMarketSymbol(market string) (instruments.Metadata, bool) {
	if s.instruments == nil {
		return instruments.Metadata{}, false
	}
	market = strings.TrimSpace(market)
	if m, ok := s.instruments.BySymbol(market); ok {
		return m, true
	}
	if i := strings.Index(market, ":"); i > 0 {
		if m, ok := s.instruments.ByAssetAndSubID(strings.ToLower(market[:i]), market[i+1:]); ok {
			return m, true
		}
	}
	return instruments.Metadata{}, false
}

// presentOwnerOrders presents a cross-market set of an owner's orders, looking up each order's
// instrument for correct display units.
func (s *Server) presentOwnerOrders(items []orders.Order) []presentedOrder {
	out := make([]presentedOrder, 0, len(items))
	for _, o := range items {
		meta, _ := s.instruments.ByAssetAndSubID(strings.ToLower(o.AssetAddress), o.SubID)
		out = append(out, presentOrders([]orders.Order{o}, meta)...)
	}
	return out
}

func marketKeyOf(meta instruments.Metadata) string {
	return strings.ToLower(meta.AssetAddress) + ":" + meta.SubID
}
