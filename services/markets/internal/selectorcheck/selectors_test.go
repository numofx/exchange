//go:build abicheck

// Package selectorcheck checks every 4-byte selector the service pins against the ABIs forge compiled from
// contracts/risk-core and contracts/execution.
//
// A selector that matches `cast sig` of its own name proves only that the two agree: a misspelt or misremembered
// name passes, and on chain the call reverts or reads empty space. For the revert classifier it is worse: an entry
// whose selector names nothing compiled never matches, and the revert it was meant for falls through to the default
// class without a sound.
//
// Behind the abicheck tag so `go test ./...` (and test-with-db.sh, where nothing may skip) does not need the
// contracts built. CI and verify.sh run it as its own step, after `forge build` in both trees:
//
//	go test -tags abicheck ./internal/selectorcheck/
package selectorcheck

import (
	"encoding/hex"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	"golang.org/x/crypto/sha3"
)

// External contracts compiled in neither tree: each selector with the signature it must be, and why it is here.
// Keep this short: every entry is a place the ABI check does not look (the signature is still checked).
var notCompiled = map[string]struct{ signature, why string }{
	"0x5c975abb": {"paused()", "cNGN's and USDC's pause flag; the tokens are external"},
	"0xe47d6060": {"isBlackListed(address)", "cNGN's admin operations contract, external"},
	"0xfe575a87": {"isBlacklisted(address)", "Circle's FiatToken (USDC), external"},
}

var (
	selectorLiteral = regexp.MustCompile(`"(0x[0-9a-fA-F]{8})"`)
	// a revert classifier entry: "0x…": {Name: "X", ...}
	namedEntry = regexp.MustCompile(`"(0x[0-9a-fA-F]{8})":\s*\{\s*Name:\s*"([A-Za-z0-9_]+)"`)
	// a selector with its signature in a trailing comment, optionally qualified: // Contract.name(args)
	commented = regexp.MustCompile(`"(0x[0-9a-fA-F]{8})"[^\n/]*//\s*(?:[A-Za-z0-9_]+\.)?([A-Za-z_][A-Za-z0-9_]*\([a-z0-9,\[\]()]*\))`)
)

func selectorOf(signature string) string {
	h := sha3.NewLegacyKeccak256()
	h.Write([]byte(signature))
	return "0x" + hex.EncodeToString(h.Sum(nil)[:4])
}

type abiParam struct {
	Type       string     `json:"type"`
	Components []abiParam `json:"components"`
}

type abiItem struct {
	Type   string     `json:"type"`
	Name   string     `json:"name"`
	Inputs []abiParam `json:"inputs"`
}

func canonical(p abiParam) string {
	if strings.HasPrefix(p.Type, "tuple") {
		parts := make([]string, len(p.Components))
		for i, c := range p.Components {
			parts[i] = canonical(c)
		}
		return "(" + strings.Join(parts, ",") + ")" + strings.TrimPrefix(p.Type, "tuple")
	}
	return p.Type
}

type compiledABI struct {
	bySelector map[string]map[string]bool // selector -> signatures
	errorNamed map[string]map[string]bool // selector -> error names
	signatures map[string]bool
}

func repoRoot(t *testing.T) string {
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for ; dir != filepath.Dir(dir); dir = filepath.Dir(dir) {
		if _, err := os.Stat(filepath.Join(dir, "contracts", "risk-core")); err == nil {
			return dir
		}
	}
	t.Fatal("repo root (with contracts/risk-core) not found above the working directory")
	return ""
}

func loadCompiled(t *testing.T, root string) compiledABI {
	c := compiledABI{map[string]map[string]bool{}, map[string]map[string]bool{}, map[string]bool{}}
	for _, tree := range []string{"risk-core", "execution"} {
		out := filepath.Join(root, "contracts", tree, "out")
		files, _ := filepath.Glob(filepath.Join(out, "*", "*.json"))
		if len(files) == 0 {
			t.Fatalf("no compiled ABIs in %s: run `forge build` in contracts/%s first", out, tree)
		}
		for _, f := range files {
			raw, err := os.ReadFile(f)
			if err != nil {
				t.Fatal(err)
			}
			var artifact struct {
				ABI []abiItem `json:"abi"`
			}
			if json.Unmarshal(raw, &artifact) != nil {
				continue
			}
			for _, item := range artifact.ABI {
				if item.Type != "function" && item.Type != "error" && item.Type != "event" {
					continue
				}
				types := make([]string, len(item.Inputs))
				for i, p := range item.Inputs {
					types[i] = canonical(p)
				}
				sig := item.Name + "(" + strings.Join(types, ",") + ")"
				sel := selectorOf(sig)
				c.signatures[sig] = true
				if c.bySelector[sel] == nil {
					c.bySelector[sel] = map[string]bool{}
				}
				c.bySelector[sel][sig] = true
				if item.Type == "error" {
					if c.errorNamed[sel] == nil {
						c.errorNamed[sel] = map[string]bool{}
					}
					c.errorNamed[sel][item.Name] = true
				}
			}
		}
	}
	return c
}

type finding struct{ where, problem string }

// check returns every problem in one source file's text.
func check(c compiledABI, where, text string) []finding {
	var out []finding
	for _, m := range namedEntry.FindAllStringSubmatch(text, -1) {
		sel, name := strings.ToLower(m[1]), m[2]
		if !c.errorNamed[sel][name] {
			out = append(out, finding{where, sel + " is not the selector of a compiled error named " + name})
		}
	}
	for _, m := range commented.FindAllStringSubmatch(text, -1) {
		sel, sig := strings.ToLower(m[1]), m[2]
		if selectorOf(sig) != sel {
			out = append(out, finding{where, sel + " is not " + sig + " (that is " + selectorOf(sig) + ")"})
		}
	}
	for _, m := range selectorLiteral.FindAllStringSubmatch(text, -1) {
		sel := strings.ToLower(m[1])
		if ext, ok := notCompiled[sel]; ok {
			if selectorOf(ext.signature) != sel {
				out = append(out, finding{where, sel + " is listed as " + ext.signature + ", which is " + selectorOf(ext.signature)})
			}
			continue
		}
		if len(c.bySelector[sel]) == 0 {
			out = append(out, finding{where, sel + " is the selector of no compiled function or error"})
		}
	}
	return out
}

func serviceSources(t *testing.T) map[string]string {
	moduleRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	sources := map[string]string{}
	err = filepath.WalkDir(moduleRoot, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() && (d.Name() == "node_modules" || d.Name() == "vendor") {
			return filepath.SkipDir
		}
		if d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(moduleRoot, path)
		sources[rel] = string(raw)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return sources
}

func TestEverySelectorNamesACompiledFunction(t *testing.T) {
	c := loadCompiled(t, repoRoot(t))
	sources := serviceSources(t)
	files := make([]string, 0, len(sources))
	for f := range sources {
		files = append(files, f)
	}
	sort.Strings(files)
	total := 0
	for _, f := range files {
		total += len(selectorLiteral.FindAllString(sources[f], -1))
		for _, p := range check(c, f, sources[f]) {
			t.Errorf("%s: %s", p.where, p.problem)
		}
	}
	if total == 0 {
		t.Fatal("found no selectors in the service: the scan is broken, not the service clean")
	}
	t.Logf("%d selector literals in %d files checked against %d compiled signatures", total, len(files), len(c.signatures))
}

// The check fires: each way a selector goes wrong is refused, and the right one passes.
func TestTheCheckFires(t *testing.T) {
	c := loadCompiled(t, repoRoot(t))
	right := selectorOf("TM_PriceTooHigh()")
	cases := []struct {
		name, text string
		want       int
	}{
		{"a correct classifier entry", `"` + right + `": {Name: "TM_PriceTooHigh", Class: x}`, 0},
		{"a classifier entry under the wrong name", `"` + right + `": {Name: "TM_PriceTooLow", Class: x}`, 1},
		{"a classifier entry for an error that does not exist", `"` + selectorOf("TM_PriceTooHot()") + `": {Name: "TM_PriceTooHot", Class: x}`, 2},
		{"a selector that is not its comment's", `"0x623bb445" // getMarginn(uint256,bool)`, 1},
		{"a misnamed function, comment and selector agreeing", `"` + selectorOf("getMarginn(uint256,bool)") + `" // getMarginn(uint256,bool)`, 1},
		{"an external token selector, listed", `"0xfe575a87" // isBlacklisted(address)`, 0},
	}
	for _, tc := range cases {
		if got := len(check(c, "case", tc.text)); got != tc.want {
			t.Errorf("%s: %d problems, want %d: %v", tc.name, got, tc.want, check(c, "case", tc.text))
		}
	}
}
