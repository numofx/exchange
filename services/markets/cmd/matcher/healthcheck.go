package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"time"
)

// runHealthcheck probes this process's own /healthz (matching.matcherHealth) and reports the result
// as an exit code: 0 while the tick loop is alive, 1 once it has stalled or the server is gone. It
// reads only MATCHER_HEALTH_ADDR, so a probe cannot fail for a reason unrelated to the matcher.
func runHealthcheck() int {
	addr := os.Getenv("MATCHER_HEALTH_ADDR")
	if addr == "" {
		addr = ":8082"
	}
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: cannot parse MATCHER_HEALTH_ADDR %q: %v\n", addr, err)
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

func isHealthcheckArg(args []string) bool {
	if len(args) != 2 {
		return false
	}
	return args[1] == "-healthcheck" || args[1] == "--healthcheck"
}
