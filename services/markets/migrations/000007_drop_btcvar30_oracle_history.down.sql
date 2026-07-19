create table if not exists oracle_btcvar30_history (
  symbol text not null,
  source text not null,
  observed_at timestamptz not null,
  vol_30d double precision not null,
  variance_30d double precision not null,
  methodology_version text not null,
  signature text not null,
  created_at timestamptz not null default now(),
  primary key (symbol, observed_at)
);

create index if not exists oracle_btcvar30_history_observed_at_idx
  on oracle_btcvar30_history (observed_at desc);
