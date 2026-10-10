package api

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
)

const (
	baseUSDC   = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
	baseCNGN   = "0x46c85152bfe9f96829aa94755d9f915f9b10ef5f"
	cngnAdmin  = "0x2a7483194a651b398582c9a935f793ec2dee2fa7"
	cngnEscrow = "0x37c976bb5d4887a714ef19af6b83e34fe2f37c98"
	trueWord   = "0x0000000000000000000000000000000000000000000000000000000000000001"
	falseWord  = "0x0000000000000000000000000000000000000000000000000000000000000000"
)

// fakeTokenState answers WrappedToken from a map and eth_call by exact (to, data); anything unscripted is false.
type fakeTokenState struct {
	tokens  map[string]string
	answers map[string]string
	errs    map[string]error
	err     error
	calls   []string
}

func (f *fakeTokenState) WrappedToken(_ context.Context, asset string) (string, error) {
	return f.tokens[strings.ToLower(asset)], nil
}

func (f *fakeTokenState) ethCall(_ context.Context, to, data string) (string, error) {
	f.calls = append(f.calls, to+" "+data)
	if f.err != nil {
		return "", f.err
	}
	if err, ok := f.errs[to+" "+data]; ok {
		return "", err
	}
	if answer, ok := f.answers[to+" "+data]; ok {
		return answer, nil
	}
	return falseWord, nil
}

func newTokenState() *fakeTokenState {
	return &fakeTokenState{
		tokens:  map[string]string{testPerpCash: baseUSDC, cngnEscrow: baseCNGN, testWrappedUSDC: baseUSDC, testWrappedCNGN: baseCNGN},
		answers: map[string]string{},
	}
}

func frozenAt(contract, selector, address string) string { return contract + " " + selector + addressArg(address) }

var withdrawalParties = func(owner, asset string) []custodyParty {
	return []custodyParty{{address: owner, role: "withdrawing owner"}, {address: asset, role: "custody contract", venue: true}}
}

func TestTokenControlsAskEachIssuerInItsOwnWay(t *testing.T) {
	owner := strings.ToLower(testWithdrawalOwner)

	usdc := newTokenState()
	if stop, err := checkTokenControls(context.Background(), usdc, testPerpCash, "withdrawal", withdrawalParties(owner, testPerpCash)); stop != nil || err != nil {
		t.Fatalf("nothing frozen: stop=%+v err=%v", stop, err)
	}
	wantUSDC := []string{
		baseUSDC + " " + sigPaused,
		frozenAt(baseUSDC, sigIsBlacklisted, owner),
		frozenAt(baseUSDC, sigIsBlacklisted, testPerpCash),
	}
	if strings.Join(usdc.calls, "\n") != strings.Join(wantUSDC, "\n") {
		t.Fatalf("USDC reads:\n%s\nwant (the token answers its own blacklist):\n%s", strings.Join(usdc.calls, "\n"), strings.Join(wantUSDC, "\n"))
	}

	cngn := newTokenState()
	if stop, err := checkTokenControls(context.Background(), cngn, cngnEscrow, "withdrawal", withdrawalParties(owner, cngnEscrow)); stop != nil || err != nil {
		t.Fatalf("nothing frozen: stop=%+v err=%v", stop, err)
	}
	wantCNGN := []string{
		baseCNGN + " " + sigPaused,
		frozenAt(cngnAdmin, sigIsBlackListed, owner),
		frozenAt(cngnAdmin, sigIsBlackListed, cngnEscrow),
	}
	if strings.Join(cngn.calls, "\n") != strings.Join(wantCNGN, "\n") {
		t.Fatalf("cNGN reads:\n%s\nwant (the admin contract answers, with its own spelling):\n%s", strings.Join(cngn.calls, "\n"), strings.Join(wantCNGN, "\n"))
	}
}

func TestTokenControlsNameWhoIsStopped(t *testing.T) {
	owner := strings.ToLower(testWithdrawalOwner)
	cases := []struct {
		name      string
		asset     string
		answer    string
		status    int
		venue     bool
		mentioned []string
	}{
		{"USDC paused", testPerpCash, baseUSDC + " " + sigPaused, http.StatusServiceUnavailable, true, []string{"USDC is paused by its issuer", "withdrawals of USDC are suspended"}},
		{"cNGN paused", cngnEscrow, baseCNGN + " " + sigPaused, http.StatusServiceUnavailable, true, []string{"cNGN is paused"}},
		{"the trader frozen by Circle", testPerpCash, frozenAt(baseUSDC, sigIsBlacklisted, owner), http.StatusBadRequest, false, []string{owner, "withdrawing owner", "USDC's issuer"}},
		{"the trader frozen by cNGN", cngnEscrow, frozenAt(cngnAdmin, sigIsBlackListed, owner), http.StatusBadRequest, false, []string{owner, "cNGN's issuer"}},
		{"the venue's USDC cash frozen", testPerpCash, frozenAt(baseUSDC, sigIsBlacklisted, testPerpCash), http.StatusServiceUnavailable, true, []string{"frozen the venue's custody contract", testPerpCash}},
		{"the venue's cNGN escrow frozen", cngnEscrow, frozenAt(cngnAdmin, sigIsBlackListed, cngnEscrow), http.StatusServiceUnavailable, true, []string{"frozen the venue's custody contract", cngnEscrow}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			state := newTokenState()
			state.answers[tc.answer] = trueWord
			stop, err := checkTokenControls(context.Background(), state, tc.asset, "withdrawal", withdrawalParties(owner, tc.asset))
			if err != nil || stop == nil {
				t.Fatalf("stop=%+v err=%v; want a stop", stop, err)
			}
			if stop.status != tc.status || stop.venue != tc.venue {
				t.Fatalf("status=%d venue=%v, want %d %v (%s)", stop.status, stop.venue, tc.status, tc.venue, stop.message)
			}
			for _, words := range tc.mentioned {
				if !strings.Contains(stop.message, words) {
					t.Fatalf("message %q does not mention %q", stop.message, words)
				}
			}
		})
	}
}

func TestTokenControlsDeferToTheSimulationWhenTheyCannotKnow(t *testing.T) {
	owner := strings.ToLower(testWithdrawalOwner)

	unreadable := newTokenState()
	unreadable.err = errors.New("rpc status 429")
	if stop, err := checkTokenControls(context.Background(), unreadable, testPerpCash, "withdrawal", withdrawalParties(owner, testPerpCash)); stop != nil || err == nil {
		t.Fatalf("an unreadable issuer must be an error the caller logs, not a stop: stop=%+v err=%v", stop, err)
	}

	unknown := newTokenState()
	unknown.tokens[testPerpCash] = "0x000000000000000000000000000000000000dead"
	if stop, err := checkTokenControls(context.Background(), unknown, testPerpCash, "withdrawal", withdrawalParties(owner, testPerpCash)); stop != nil || err != nil || len(unknown.calls) != 0 {
		t.Fatalf("a token with no known controls is not read: stop=%+v err=%v calls=%v", stop, err, unknown.calls)
	}
}

// The wiring: each handler runs the check, with its own parties, before anything reaches the executor.

func TestWithdrawalRefusesAFrozenOwnerAndSuspendsOnAFrozenEscrowWithoutSubmitting(t *testing.T) {
	owner := strings.ToLower(testWithdrawalOwner)
	for _, tc := range []struct {
		answer string
		status int
	}{
		{frozenAt(baseUSDC, sigIsBlacklisted, owner), http.StatusBadRequest},
		{frozenAt(baseUSDC, sigIsBlacklisted, testWrappedUSDC), http.StatusServiceUnavailable},
		{baseUSDC + " " + sigPaused, http.StatusServiceUnavailable},
	} {
		h := newWithdrawalHarness()
		state := newTokenState()
		state.answers[tc.answer] = trueWord
		h.server.withdrawals.tokens = state
		rec := postWithdrawal(t, h.server, validWithdrawal())
		if rec.Code != tc.status || !strings.Contains(rec.Body.String(), "issuer") {
			t.Fatalf("%s: status=%d body=%s, want %d naming the issuer", tc.answer, rec.Code, rec.Body.String(), tc.status)
		}
		if h.submitter.received != nil {
			t.Fatalf("%s: a stopped withdrawal reached the executor", tc.answer)
		}
	}
}

func TestWithdrawalGoesThroughWhenTheIssuerCannotBeRead(t *testing.T) {
	h := newWithdrawalHarness()
	state := newTokenState()
	state.err = errors.New("rpc status 429")
	h.server.withdrawals.tokens = state
	if rec := postWithdrawal(t, h.server, validWithdrawal()); rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s; an unreadable issuer must not block a withdrawal the chain would allow", rec.Code, rec.Body.String())
	}
}

func TestDepositChecksTheDepositModuleAsWellAsTheOwnerAndTheCustodyContract(t *testing.T) {
	owner := strings.ToLower(testWithdrawalOwner)
	for _, tc := range []struct {
		answer string
		status int
	}{
		{frozenAt(baseUSDC, sigIsBlacklisted, owner), http.StatusBadRequest},
		{frozenAt(baseUSDC, sigIsBlacklisted, testDepositModule), http.StatusServiceUnavailable},
		{frozenAt(baseUSDC, sigIsBlacklisted, testPerpCash), http.StatusServiceUnavailable},
		{baseUSDC + " " + sigPaused, http.StatusServiceUnavailable},
	} {
		h := newDepositHarness()
		state := newTokenState()
		state.answers[tc.answer] = trueWord
		h.server.deposits.tokens = state
		rec := postDeposit(t, h.server, validDeposit())
		expectDeposit(t, rec, tc.status, "issuer")
		if h.submitter.received != nil {
			t.Fatalf("%s: a stopped deposit reached the executor", tc.answer)
		}
	}
}
