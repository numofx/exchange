package options

import (
	"context"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/config"
)

// assetDetails answers (isWhitelisted, assetType, marketId): word 1 the type, word 2 the market. A stub where they differ
// (an option on market 3) is what reading word 1 as the market id would get wrong.
func assetDetailsStub(t *testing.T, whitelisted, assetType, marketID int64) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result := "0x" + uintWord(big.NewInt(whitelisted)) + uintWord(big.NewInt(assetType)) + uintWord(big.NewInt(marketID))
		fmt.Fprintf(w, `{"jsonrpc":"2.0","id":1,"result":%q}`, result)
	}))
}

func stubReader(url string) *Reader {
	fee := 15
	return NewReader(url, config.OptionSeries{AssetAddress: "0x" + strings.Repeat("a1", 20), ManagerAddress: "0x" + strings.Repeat("e2", 20),
		VolFeedAddress: "0x" + strings.Repeat("b1", 20), BaseAsset: "cNGN", Expiry: 1796047200, TakerFeeBps: &fee}, time.Second)
}

func TestMarketIDIsAssetDetailsWordTwo(t *testing.T) {
	rpc := assetDetailsStub(t, 1, assetTypeOption, 3)
	defer rpc.Close()
	id, err := stubReader(rpc.URL).market(context.Background())
	if err != nil || id.Int64() != 3 {
		t.Fatalf("an option on market 3 reads as market %v (%v)", id, err)
	}
}

func TestMarketRefusesAnAssetThatIsNotAnOption(t *testing.T) {
	rpc := assetDetailsStub(t, 1, 3 /* Base */, 1)
	defer rpc.Close()
	if _, err := stubReader(rpc.URL).market(context.Background()); err == nil || !strings.Contains(err.Error(), "not an option") {
		t.Fatalf("a base asset was taken for an option: %v", err)
	}
	unlisted := assetDetailsStub(t, 0, assetTypeOption, 1)
	defer unlisted.Close()
	if _, err := stubReader(unlisted.URL).market(context.Background()); err == nil {
		t.Fatal("an unwhitelisted option was accepted")
	}
}
