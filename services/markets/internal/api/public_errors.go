package api

import (
	"regexp"
)

// urlInMessage matches any URL in an error's text. Go's HTTP client names the URL it failed on, and an RPC URL holds
// its API key, so a failed chain read can carry the key in its message.
var urlInMessage = regexp.MustCompile(`[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s"'\\]+`)

// publicErrorMessage is err's text with any URL removed, for an answer a client reads. Log err itself for the detail.
func publicErrorMessage(err error) string {
	return urlInMessage.ReplaceAllString(err.Error(), "<url>")
}

func errorBody(err error) map[string]string {
	return map[string]string{"error": publicErrorMessage(err)}
}
