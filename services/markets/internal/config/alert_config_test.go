package config

import "testing"

// The matcher posts settlement failures to ALERT_WEBHOOK_URL -- the same secret execution-service reads.
func TestAlertWebhookURLIsReadFromTheEnvironment(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://test")
	t.Setenv("APP_ENV", "test")
	t.Setenv("ALERT_WEBHOOK_URL", "  https://hooks.example.invalid/x  ")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AlertWebhookURL != "https://hooks.example.invalid/x" {
		t.Fatalf("AlertWebhookURL = %q", cfg.AlertWebhookURL)
	}
}
