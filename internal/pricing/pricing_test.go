package pricing
 
import (
	"testing"

	"github.com/numofx/matching-backend/internal/instruments"
)

func TestParsePreservesIntegerInstrument(t *testing.T) {
	converter, err := NewConverter(instruments.Metadata{
		Symbol:         "USDCcNGN-JUN30-2026",
		TickSize:       "1",
		QuotePrecision: 6,
	})
	if err != nil {
		t.Fatalf("NewConverter returned error: %v", err)
	}

	ticks, normalized, err := converter.Parse("40")
	if err != nil {
		t.Fatalf("Parse returned error: %v", err)
	}
	if ticks != "40" || normalized != "40" {
		t.Fatalf("unexpected result ticks=%s normalized=%s", ticks, normalized)
	}
}

func TestParseRejectsOffTickPrice(t *testing.T) {
	converter, err := NewConverter(instruments.Metadata{
		Symbol:         "USDCcNGN-JUN30-2026",
		TickSize:       "0.01",
		QuotePrecision: 18,
	})
	if err != nil {
		t.Fatalf("NewConverter returned error: %v", err)
	}

	if _, _, err := converter.Parse("0.27245"); err == nil {
		t.Fatal("expected off-tick price to fail")
	}
}
