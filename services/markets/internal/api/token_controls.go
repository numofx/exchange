package api

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
)

// Every token the venue holds in custody can be stopped by its issuer: the whole token paused, or one address
// frozen. Either makes a deposit or withdrawal revert, and the revert does not say who is frozen -- USDC answers
// "Blacklistable: account is blacklisted" for every party, and cNGN's "Sender is blacklisted" means the trader on a
// deposit but the venue's escrow on a withdrawal. Verified on a Base fork (2026-10-10) by freezing each party in turn:
//
//	deposit:    the owner, the DepositModule, or the wrapped asset contract frozen -> reverts; Matching, executor -> fine
//	withdrawal: the owner or the wrapped asset contract frozen                     -> reverts; DepositModule -> fine
//	either:     the token paused -> "Pausable: paused". cNGN's admin contract also has a pause; it does not stop transfers.
//
// So the API reads the issuer's own state before submitting and says which it is. A frozen owner is the trader's to
// resolve with the issuer (400). A paused token or a frozen venue contract stops everyone, so it is a 503 and an
// operator problem; the execution-service canary pages on the same state without waiting for a trader to hit it.
const (
	sigPaused        = "0x5c975abb" // paused()
	sigIsBlacklisted = "0xfe575a87" // isBlacklisted(address): Circle FiatToken
	sigIsBlackListed = "0xe47d6060" // isBlackListed(address): cNGN's admin operations contract
)

// tokenControl is how one token's issuer can stop a transfer.
type tokenControl struct {
	symbol string
	// blacklist answers the per-address freeze query: the token itself for USDC, a separate admin contract for cNGN.
	blacklist string
	selector  string
}

// knownTokenControls, by lowercased token address on Base. A token not listed is not checked here; the executor's
// simulation still refuses a transfer the token would revert, with the token's own words.
var knownTokenControls = map[string]tokenControl{
	"0x833589fcd6edb6e08f4c7c32d4f71b54bda02913": {symbol: "USDC", blacklist: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", selector: sigIsBlacklisted},
	"0x46c85152bfe9f96829aa94755d9f915f9b10ef5f": {symbol: "cNGN", blacklist: "0x2a7483194a651b398582c9a935f793ec2dee2fa7", selector: sigIsBlackListed},
}

// tokenStateReader is the chain access the check needs: which token a wrapped asset holds, and one eth_call.
type tokenStateReader interface {
	WrappedToken(ctx context.Context, asset string) (string, error)
	ethCall(ctx context.Context, contractAddress string, data string) (string, error)
}

// custodyParty is an address a transfer touches, and whether it is the venue's (frozen: everyone is stopped) or the
// trader's (frozen: only they are).
type custodyParty struct {
	address string
	role    string
	venue   bool
}

// custodyStop is a refusal: the status to answer with, the message, and whether it stops the venue rather than one
// trader.
type custodyStop struct {
	status  int
	message string
	venue   bool
}

// checkTokenControls reads the asset's token's pause and each party's freeze. A stop is returned when one applies; an
// error when the issuer's state could not be read, which callers treat as "not known" and let the executor's
// simulation decide, because this check only improves the message and must not add an outage of its own.
func checkTokenControls(ctx context.Context, chain tokenStateReader, asset, operation string, parties []custodyParty) (*custodyStop, error) {
	token, err := chain.WrappedToken(ctx, asset)
	if err != nil {
		return nil, err
	}
	control, ok := knownTokenControls[strings.ToLower(token)]
	if !ok {
		return nil, nil
	}

	raw, err := chain.ethCall(ctx, token, sigPaused)
	if err != nil {
		return nil, err
	}
	if paused, err := unsignedWord(raw); err != nil {
		return nil, err
	} else if paused.Sign() != 0 {
		return &custodyStop{
			status:  http.StatusServiceUnavailable,
			message: fmt.Sprintf("%s is paused by its issuer, so no %s can move; %ss of %s are suspended until it is unpaused", control.symbol, control.symbol, operation, control.symbol),
			venue:   true,
		}, nil
	}

	for _, party := range parties {
		raw, err := chain.ethCall(ctx, control.blacklist, control.selector+addressArg(party.address))
		if err != nil {
			return nil, err
		}
		frozen, err := unsignedWord(raw)
		if err != nil {
			return nil, err
		}
		if frozen.Sign() == 0 {
			continue
		}
		if party.venue {
			return &custodyStop{
				status: http.StatusServiceUnavailable,
				message: fmt.Sprintf("%s's issuer has frozen the venue's %s (%s); %ss of %s are suspended until it is unfrozen",
					control.symbol, party.role, party.address, operation, control.symbol),
				venue: true,
			}, nil
		}
		return &custodyStop{
			status: http.StatusBadRequest,
			message: fmt.Sprintf("%s's issuer has frozen %s (the %s), so it cannot send or receive %s; this is between that address and %s's issuer",
				control.symbol, party.address, party.role, control.symbol, control.symbol),
		}, nil
	}
	return nil, nil
}

// logTokenStop records a refusal. A venue-wide stop is logged as an error: it is an outage for every holder of the
// token, and the canary pages on it independently.
func logTokenStop(operation, owner, asset string, stop *custodyStop) {
	if stop.venue {
		slog.Error(operation+"_suspended", "stage", "token_controls", "owner", owner, "asset", asset, "reason", stop.message)
		return
	}
	slog.Info(operation+"_rejected", "stage", "token_controls", "owner", owner, "asset", asset, "reason", stop.message)
}
