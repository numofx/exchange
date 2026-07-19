package matching

import (
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/orders"
)

func TestCrosses(t *testing.T) {
	now := time.Unix(1700000000, 0)

	tests := []struct {
		name    string
		taker   orders.Order
		maker   orders.Order
		want    bool
		wantErr bool
	}{
		{
			name:  "buy taker crosses lower sell maker",
			taker: orders.Order{Side: orders.SideBuy, LimitPrice: "100", LimitPriceTicks: "100", CreatedAt: now},
			maker: orders.Order{Side: orders.SideSell, LimitPrice: "90", LimitPriceTicks: "90", CreatedAt: now.Add(-time.Second)},
			want:  true,
		},
		{
			name:  "buy taker crosses by one tick",
			taker: orders.Order{Side: orders.SideBuy, LimitPrice: "1391", LimitPriceTicks: "1391", CreatedAt: now},
			maker: orders.Order{Side: orders.SideSell, LimitPrice: "1390", LimitPriceTicks: "1390", CreatedAt: now.Add(-time.Second)},
			want:  true,
		},
		{
			name:  "sell taker crosses higher buy maker",
			taker: orders.Order{Side: orders.SideSell, LimitPrice: "90", LimitPriceTicks: "90", CreatedAt: now},
			maker: orders.Order{Side: orders.SideBuy, LimitPrice: "100", LimitPriceTicks: "100", CreatedAt: now.Add(-time.Second)},
			want:  true,
		},
		{
			name:  "buy taker does not cross",
			taker: orders.Order{Side: orders.SideBuy, LimitPrice: "80", LimitPriceTicks: "80", CreatedAt: now},
			maker: orders.Order{Side: orders.SideSell, LimitPrice: "90", LimitPriceTicks: "90", CreatedAt: now.Add(-time.Second)},
			want:  false,
		},
		{
			name:  "decimal display prices cross when canonical ticks cross",
			taker: orders.Order{Side: orders.SideBuy, LimitPrice: "0.2725", LimitPriceTicks: "2725", CreatedAt: now},
			maker: orders.Order{Side: orders.SideSell, LimitPrice: "0.2724", LimitPriceTicks: "2724", CreatedAt: now.Add(-time.Second)},
			want:  true,
		},
		{
			name:    "invalid price",
			taker:   orders.Order{Side: orders.SideBuy, LimitPrice: "bad", LimitPriceTicks: "bad", CreatedAt: now},
			maker:   orders.Order{Side: orders.SideSell, LimitPrice: "90", LimitPriceTicks: "90", CreatedAt: now.Add(-time.Second)},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := crosses(tt.taker, tt.maker)
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error")
				}
				return
			}
			if err != nil {
				t.Fatalf("crosses returned error: %v", err)
			}
			if got != tt.want {
				t.Fatalf("crosses = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestFillAmountIsNonZeroForAtomicLot(t *testing.T) {
	taker := orders.Order{DesiredAmount: "1", FilledAmount: "0"}
	maker := orders.Order{DesiredAmount: "1", FilledAmount: "0"}

	fillAmount, err := minDecimalString(remainingAmount(taker), remainingAmount(maker))
	if err != nil {
		t.Fatalf("compute fill amount: %v", err)
	}
	if fillAmount != "1" {
		t.Fatalf("fill amount = %s", fillAmount)
	}
}

func TestShouldFinalizeAfterExecutorError(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{
			name: "decoded contract error name",
			err:  errString("executor returned status 500: TM_FillLimitCrossed()"),
			want: true,
		},
		{
			name: "raw contract selector",
			err:  errString("executor returned status 500: 0xfea8fa6f"),
			want: true,
		},
		{
			name: "unrelated executor error",
			err:  errString("executor returned status 500: connection reset"),
			want: false,
		},
		{
			name: "nil error",
			err:  nil,
			want: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := shouldFinalizeAfterExecutorError(tt.err); got != tt.want {
				t.Fatalf("shouldFinalizeAfterExecutorError() = %v, want %v", got, tt.want)
			}
		})
	}
}

type errString string

func (e errString) Error() string {
	return string(e)
}
