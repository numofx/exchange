package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/orders"
	"github.com/numofx/matching-backend/internal/ordersig"
)

// signatureChecker verifies that an order's signature authorizes its action, reporting which path
// authorized it so a contract signature can be told apart from an EOA one.
type signatureChecker interface {
	Verify(
		ctx context.Context,
		action ordersig.Action,
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
