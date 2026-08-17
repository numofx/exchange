package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/orders"
	"github.com/numofx/matching-backend/internal/ordersig"
)

// signatureChecker verifies that an order's or cancel's signature authorizes it, reporting which
// path authorized it so a contract signature can be told apart from an EOA one.
type signatureChecker interface {
	Verify(
		ctx context.Context,
		action ordersig.Action,
		signature string,
		signerAddress string,
	) (ordersig.SignaturePath, error)
	VerifyCancel(
		ctx context.Context,
		cancel ordersig.Cancel,
		signature string,
		signerAddress string,
	) (ordersig.SignaturePath, error)
}

// newSignatureChecker returns nil when the service is not configured to verify signatures, which
// leaves submission behaving exactly as it did before.
func newSignatureChecker(cfg config.Config) signatureChecker {
	v := ordersig.NewVerifier(cfg.ChainID, cfg.MatchingAddress, cfg.ChainRPCURL)
	if v == nil {
		return nil
	}
	return v
}

// verifyOrderSignature checks the order's signature and logs the outcome. The returned error is
// what the client would see if enforcement were on; the caller decides whether to act on it.
//
// A check that could not be completed — an RPC failure while resolving a contract signer — is
// logged but not returned. Enforcing on it would reject valid orders during an RPC blip, which
// is the same reasoning the matcher's backoff applies to transient failures.
func (s *Server) verifyOrderSignature(ctx context.Context, req createOrderRequest, params orders.CreateOrderParams) error {
	if s.signatures == nil {
		return nil
	}

	action, err := actionFromJSON(req.ActionJSON)
	if err != nil {
		slog.Warn("order_signature_unverifiable", "order_id", params.OrderID, "error", err)
		return nil
	}

	path, err := s.signatures.Verify(ctx, action, req.Signature, params.SignerAddress)
	switch {
	case err == nil:
		// Only the contract path is logged. An EOA signature is settled locally and is already
		// evidenced by the order being accepted under enforcement; a contract signature is the
		// one that reaches out to the chain, and without this line a successful ERC-1271 check
		// is indistinguishable from an EOA one — which left that branch unobservable in
		// production even while it was enforcing.
		if path == ordersig.PathERC1271 {
			slog.Info(
				"order_signature_verified",
				"order_id", params.OrderID,
				"signer_address", params.SignerAddress,
				"path", string(path),
			)
		}
		return nil
	case errors.Is(err, ordersig.ErrInvalidSignature):
		slog.Warn(
			"order_signature_invalid",
			"order_id", params.OrderID,
			"signer_address", params.SignerAddress,
			"enforced", s.cfg.EnforceOrderSignatures,
			"error", err,
		)
		return fmt.Errorf("signature does not authorize this action")
	default:
		slog.Warn("order_signature_unverifiable", "order_id", params.OrderID, "error", err)
		return nil
	}
}

// verifyCancelSignature checks that a cancel is authorized and logs the outcome, mirroring
// verifyOrderSignature. The returned error is the actionable rejection — a missing, malformed, or
// invalid signature, a non-owner signer, or a missing/expired validity window — which the caller
// enforces only when EnforceCancelSignatures is on. A check that could not be completed (an RPC
// failure resolving a contract signer) returns nil: enforcing on an infra blip would reject valid
// cancels, the same reasoning verifyOrderSignature applies.
//
// now is passed in so the expiry check is testable.
func (s *Server) verifyCancelSignature(ctx context.Context, req cancelOrderRequest, now time.Time) error {
	if s.signatures == nil {
		return nil
	}

	owner := strings.ToLower(strings.TrimSpace(req.OwnerAddress))
	signer := req.signerOrOwner()

	if strings.TrimSpace(req.Signature) == "" {
		slog.Warn("cancel_signature_missing", "owner", owner, "nonce", req.Nonce, "enforced", s.cfg.EnforceCancelSignatures)
		return fmt.Errorf("cancel must be signed")
	}
	// Session keys are not supported for cancels yet: there is no on-chain registry to resolve a
	// signer that is not the owner, so require them to match. Relaxing this is the session-key step.
	if signer != owner {
		slog.Warn("cancel_signature_signer_not_owner", "owner", owner, "signer", signer, "enforced", s.cfg.EnforceCancelSignatures)
		return fmt.Errorf("cancel signer must be the owner")
	}
	// A cancel signature with no future expiry could be replayed indefinitely.
	expiry, err := parseFutureUnix(req.Expiry, now)
	if err != nil {
		slog.Warn("cancel_signature_expiry_invalid", "owner", owner, "nonce", req.Nonce, "error", err, "enforced", s.cfg.EnforceCancelSignatures)
		return fmt.Errorf("cancel expiry: %w", err)
	}

	cancel := ordersig.Cancel{
		Owner:  owner,
		Signer: signer,
		Nonce:  strings.TrimSpace(req.Nonce),
		Expiry: strconv.FormatInt(expiry, 10),
	}
	path, err := s.signatures.VerifyCancel(ctx, cancel, req.Signature, signer)
	switch {
	case err == nil:
		if path == ordersig.PathERC1271 {
			slog.Info("cancel_signature_verified", "owner", owner, "nonce", req.Nonce, "path", string(path))
		}
		return nil
	case errors.Is(err, ordersig.ErrInvalidSignature):
		slog.Warn("cancel_signature_invalid", "owner", owner, "nonce", req.Nonce, "enforced", s.cfg.EnforceCancelSignatures, "error", err)
		return fmt.Errorf("signature does not authorize this cancel")
	default:
		slog.Warn("cancel_signature_unverifiable", "owner", owner, "nonce", req.Nonce, "error", err)
		return nil
	}
}

// parseFutureUnix parses a base-10 unix-seconds string and requires it to be strictly in the
// future relative to now.
func parseFutureUnix(raw string, now time.Time) (int64, error) {
	value, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("must be a unix-seconds integer")
	}
	if value <= now.Unix() {
		return 0, fmt.Errorf("must be in the future")
	}
	return value, nil
}

// actionFromJSON pulls the seven Action fields out of action_json. The values are used only to
// rebuild the signed digest; their consistency with the order body is already enforced by
// validateActionJSON.
func actionFromJSON(raw json.RawMessage) (ordersig.Action, error) {
	var action struct {
		SubaccountID string `json:"subaccount_id"`
		Nonce        string `json:"nonce"`
		Module       string `json:"module"`
		Data         string `json:"data"`
		Expiry       string `json:"expiry"`
		Owner        string `json:"owner"`
		Signer       string `json:"signer"`
	}
	if err := json.Unmarshal(raw, &action); err != nil {
		return ordersig.Action{}, fmt.Errorf("parse action_json: %w", err)
	}
	return ordersig.Action{
		SubaccountID: action.SubaccountID,
		Nonce:        action.Nonce,
		Module:       action.Module,
		Data:         action.Data,
		Expiry:       action.Expiry,
		Owner:        action.Owner,
		Signer:       action.Signer,
	}, nil
}
