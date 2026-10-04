-- A row per long-running process that wants to be known alive: the matcher writes its own every few
-- seconds with what it last did (tick, position-indexer cursor and head). markets-service serves it
-- on GET /v1/health so the pager, outside the cluster, can tell a dead matcher from a quiet one.
create table if not exists service_heartbeats (
  service text primary key,
  last_seen_at timestamptz not null,
  details jsonb not null default '{}'::jsonb
);
