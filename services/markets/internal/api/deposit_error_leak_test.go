package api

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/numofx/matching-backend/migrations"
)

// A deposit record is public (GET /v1/deposits/{action_hash}, no auth). A failed submission's error can carry the
// executor's URL, or, in an execution-service 500, its RPC's, and an Alchemy RPC URL holds the API key (#229).
const depositLeakKey = "alch_TESTKEY_must_not_leak_0123456789"

func captureLogs(t *testing.T) *bytes.Buffer {
	t.Helper()
	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })
	return &logs
}

func assertNoDepositLeak(t *testing.T, what string, body string) {
	t.Helper()
	if strings.Contains(body, depositLeakKey) || strings.Contains(body, "/v2/") || strings.Contains(body, "127.0.0.1") {
		t.Fatalf("%s carries the URL: %s", what, body)
	}
}

// Both ways a submission fails without a refusal, through the real executor client: an execution-service 500 whose
// body is viem's transport error (the RPC URL with its key), and an executor that cannot be reached at a keyed URL.
// The POST answer and the stored record say the fixed message; the log has the detail.
func TestAFailedDepositSubmissionNeverPublishesTheURL(t *testing.T) {
	executor500 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		fmt.Fprintf(w, `{"error":"HTTP request failed.\n\nURL: https://base-mainnet.g.alchemy.com/v2/%s\nRequest body: {\"method\":\"eth_call\"}\n\nDetails: fetch failed"}`, depositLeakKey)
	}))
	defer executor500.Close()
	dead := httptest.NewServer(http.NotFoundHandler())
	dead.Close()

	for name, url := range map[string]string{
		"execution-service 500 with the RPC URL": executor500.URL,
		"executor unreachable at a keyed URL":    dead.URL + "/v2/" + depositLeakKey,
	} {
		t.Run(name, func(t *testing.T) {
			logs := captureLogs(t)
			h := newDepositHarness()
			h.server.deposits.submitter = &executorDepositClient{url: url, httpClient: &http.Client{Timeout: 5 * time.Second}}

			post := postDeposit(t, h.server, validDeposit())
			expectDeposit(t, post, http.StatusBadGateway, "could not confirm whether the deposit was submitted")
			assertNoDepositLeak(t, "the POST answer", post.Body.String())

			get := getDeposit(t, h.server, actionHashOf(t, validDeposit()))
			expectDeposit(t, get, http.StatusOK, `"status":"unknown"`)
			assertNoDepositLeak(t, "the record", get.Body.String())
			if !strings.Contains(get.Body.String(), depositUnconfirmedMessage) {
				t.Fatalf("the record says the fixed message: %s", get.Body.String())
			}
			stored, _, _ := h.server.deposits.store.Get(context.Background(), actionHashOf(t, validDeposit()))
			if stored.Error != depositUnconfirmedMessage {
				t.Fatalf("the fixed message is what is stored, got %q", stored.Error)
			}
			if !strings.Contains(logs.String(), depositLeakKey) {
				t.Fatalf("the detail is logged on the server; logs:\n%s", logs.String())
			}
		})
	}
}

// Rows written before the fix hold the raw error, including ones that later resolved (a receipt read moved them to
// confirmed or reverted and kept the error). Every such row shows the fixed message; a refusal shows its own.
func TestADepositRecordShowsOnlyARefusalsOwnError(t *testing.T) {
	h := newDepositHarness()
	raw := "execution-service returned 500: {\"error\":\"HTTP request failed.\\n\\nURL: https://base-mainnet.g.alchemy.com/v2/" + depositLeakKey + "\"}"
	for i, tc := range []struct {
		status, stored, want string
	}{
		{depositUnknown, raw, depositUnconfirmedMessage},
		{depositConfirmed, raw, depositUnconfirmedMessage},
		{depositReverted, raw, depositUnconfirmedMessage},
		{depositRejected, "deposit would revert: MW_UnknownManager", "deposit would revert: MW_UnknownManager"},
		{depositConfirmed, "", ""},
	} {
		hash := fmt.Sprintf("0x%064x", i+1)
		rec := depositRecord{ActionHash: hash, Owner: "0xowner", Nonce: "7", SubaccountIDRequested: "0", AmountUnits: "1000000000"}
		claimed, _, _ := h.server.deposits.store.Claim(context.Background(), rec)
		claimed.Status, claimed.Error = tc.status, tc.stored
		if err := h.server.deposits.store.Save(context.Background(), claimed); err != nil {
			t.Fatal(err)
		}
		body := getDepositBody(t, h.server, hash)
		assertNoDepositLeak(t, tc.status+" record", fmt.Sprint(body))
		if got := fmt.Sprint(body["error"]); got != tc.want {
			t.Fatalf("%s row holding %q shows %q, want %q", tc.status, tc.stored, got, tc.want)
		}
	}
}

// 000023 replaces the raw errors already stored, against the migrated test database: every row but a refusal, and
// nothing else in the row.
func TestScrubDepositErrorsMigration(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	up, err := migrations.Files.ReadFile("000023_scrub_deposit_errors.up.sql")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(up), "'"+depositUnconfirmedMessage+"'") {
		t.Fatal("the migration writes a message other than depositUnconfirmedMessage")
	}
	raw := "post deposit to execution-service: Post \"http://127.0.0.1:1/v2/" + depositLeakKey + "\": dial tcp"
	prefix := fmt.Sprintf("0x%060x", time.Now().UnixNano()%(1<<40))
	rows := []struct{ suffix, status, err, want string }{
		{"0001", depositUnknown, raw, depositUnconfirmedMessage},
		{"0002", depositConfirmed, raw, depositUnconfirmedMessage},
		{"0003", depositRejected, "deposit would revert: MW_UnknownManager", "deposit would revert: MW_UnknownManager"},
		{"0004", depositConfirmed, "", ""},
	}
	t.Cleanup(func() { _, _ = pool.Exec(ctx, "delete from deposits where action_hash like $1", prefix+"%") })
	for _, row := range rows {
		if _, err := pool.Exec(ctx, `insert into deposits (action_hash, owner, nonce, subaccount_id_requested, amount_units, status, tx_hash, error)
			values ($1, '0xowner', '7', '0', 1000000000, $2, '0xd5', nullif($3, ''))`, prefix+row.suffix, row.status, row.err); err != nil {
			t.Fatal(err)
		}
	}
	for run := 0; run < 2; run++ { // a second run changes nothing
		if _, err := pool.Exec(ctx, string(up)); err != nil {
			t.Fatalf("run %d: %v", run, err)
		}
	}
	for _, row := range rows {
		var got, txHash string
		if err := pool.QueryRow(ctx, "select coalesce(error, ''), tx_hash from deposits where action_hash = $1", prefix+row.suffix).Scan(&got, &txHash); err != nil {
			t.Fatal(err)
		}
		if got != row.want || txHash != "0xd5" {
			t.Fatalf("%s row: error %q tx %q, want %q and the tx untouched", row.status, got, txHash, row.want)
		}
	}
}
