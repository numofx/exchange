package orders

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Heartbeat is one process's last sign of life, as service_heartbeats holds it.
type Heartbeat struct {
	Service    string
	LastSeenAt time.Time
	Details    json.RawMessage
}

// RecordHeartbeat upserts the service's row with the database's clock, so readers compare ages
// against one clock rather than two hosts'.
func (r *Repository) RecordHeartbeat(ctx context.Context, service string, details any) error {
	encoded, err := json.Marshal(details)
	if err != nil {
		return err
	}
	_, err = r.pool.Exec(ctx, `
insert into service_heartbeats (service, last_seen_at, details) values ($1, now(), $2::jsonb)
on conflict (service) do update set last_seen_at = now(), details = excluded.details`, service, string(encoded))
	return mapPGError(err)
}

// ReadHeartbeat returns the row and the database's current time, so the caller's age is measured on
// the clock the row was written with. ok is false when the service has never reported.
func (r *Repository) ReadHeartbeat(ctx context.Context, service string) (beat Heartbeat, dbNow time.Time, ok bool, err error) {
	var details []byte
	err = r.pool.QueryRow(ctx, `select service, last_seen_at, details::text, now() from service_heartbeats where service = $1`, service).
		Scan(&beat.Service, &beat.LastSeenAt, &details, &dbNow)
	if errors.Is(err, pgx.ErrNoRows) {
		return Heartbeat{}, time.Time{}, false, nil
	}
	if err != nil {
		return Heartbeat{}, time.Time{}, false, mapPGError(err)
	}
	beat.Details = json.RawMessage(details)
	return beat, dbNow, true, nil
}
