# Production database changes

Every change made by hand to the production markets database (RDS `numo-exchange-pg`, database `markets`), recorded
the same day. Migrations are not listed here; they are in `services/markets/migrations`. Newest first.

How to run SQL there: the database accepts connections only from the app tier's security group, and the ops box is in
another VPC with no peering, so it cannot reach it. Run the `numo-exchange-pgload` task definition once with an
override command (`aws ecs run-task --cluster numo-exchange --launch-type FARGATE --task-definition
numo-exchange-pgload:3`, the markets-service subnets and security group, `assignPublicIp=DISABLED`, `--overrides`
naming the `pgload` container). It connects as `numo` through `TARGET_URL` (SSM `/numo/exchange/database_url`) and logs
to `/ecs/numo-exchange/migrate`, stream prefix `pgload`. Mask connection strings in anything it prints, as `pgload`'s
own script does.

## 2026-10-19 15:57–16:01 UTC: deposit error-leak audit (#229, before #231's migration 000023)

- **Why.** Before #231, a failed deposit submission stored the raw error on a public deposit record
  (`GET /v1/deposits/{action_hash}`), and an execution-service 500 could carry its RPC URL, Alchemy key included.
  Migration 000023 overwrites those errors and cannot be undone, so every possibly leaked row was copied aside first,
  classified, and its reads were to be traced in the ALB access logs.
- **What.**
  1. Task `arn:aws:ecs:us-east-1:957261948743:task/numo-exchange/834a959b84d948d897198bbc20de7f81`
     (started by `leak-audit-229`, 15:57:59–15:58:26 UTC, exit 0). Refused unless connected to `markets`, and stopped
     if the table already existed (it did not). Then, in one transaction:

     ```sql
     create table public.deposits_leak_audit_20261019 as
       select * from deposits
       where error like '%://%' or error ilike '%alchemy%';
     revoke all on public.deposits_leak_audit_20261019 from public;
     ```

     It then read the owner and grants, and classified each row as (a) an `alchemy.com` URL with a `/v2/` key,
     (b) any other URL or (c) neither, printing only `action_hash`, `status`, timestamps, the class and URL hosts with
     any credentials stripped.
  2. Task `arn:aws:ecs:us-east-1:957261948743:task/numo-exchange/72dd835059d642648f97456de45d0b96`
     (started by `leak-audit-229-drop`, 16:01:06–16:01:30 UTC, exit 0). Stopped unless the table existed and had 0
     rows (it had 0), then:

     ```sql
     drop table public.deposits_leak_audit_20261019;
     ```

     It also listed the deposits holding an error, by `action_hash` and `status` only.
- **Result.** `deposits` held 4 records, 1 with an error, and that error contains neither `://` nor `alchemy`: **0 rows
  matched**, so the backup table was created empty and nothing was classified. No key or URL was ever stored on a
  deposit record, and no key rotation was needed. The one errored record (`0xef64a214…1647f`, 2026-10-10) is
  `rejected`, so 000023 does not touch it and the API keeps showing its own error.
- **Log coverage.** The ALB access logs (`numo-exchange-alb-logs-957261948743`, 30-day retention) are the only record
  of request paths; markets-service logs none for reads. They held every day from 2026-10-07 to 2026-10-19, and deposit
  records exist only from 2026-10-09, so any row's whole lifetime would have been covered. With no rows there was
  nothing to trace.
- **Grants (for the record).** The table was owned by `numo` with no other grants; `PUBLIC` had none. `numo` is the
  only login role, a member of `rds_superuser`, and every service connects as it, so a table cannot be hidden from the
  services by grants (#232 proposes per-service roles).
- **State now.** The table no longer exists. Nothing else in the database was changed.
- **Undo.** Nothing to undo.
