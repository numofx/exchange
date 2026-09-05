package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"time"
)

// runHealthcheck probes this process's own /healthz and reports the result as an
// exit code. It exists because the runtime image is distroless: there is no shell
// and no wget, so the container health check has to be the binary itself.
//
// It deliberately does not call config.Load or open a database pool. A health check
// that needs the full config can fail for reasons that have nothing to do with the
// server's health, and one that opens its own pool adds a connection per probe.
func runHealthcheck() int {
	addr := os.Getenv("API_ADDR")
	if addr == "" {
		addr = ":8080"
	}

	// API_ADDR is a listen address (":8080", "0.0.0.0:8080"). Probe the loopback
	// interface regardless of which interface the server binds.
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: cannot parse API_ADDR %q: %v\n", addr, err)
		return 1
	}

	client := &http.Client{Timeout: 3 * time.Second}
	url := "http://127.0.0.1:" + port + "/healthz"

	resp, err := client.Get(url)
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: %v\n", err)
		return 1
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "healthcheck: %s returned %d\n", url, resp.StatusCode)
		return 1
	}
	return 0
}

// isHealthcheckArg reports whether the process was invoked purely to probe itself.
func isHealthcheckArg(args []string) bool {
	if len(args) != 2 {
		return false
	}
	return args[1] == "-healthcheck" || args[1] == "--healthcheck"
}
