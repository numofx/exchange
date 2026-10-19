-- Deposits whose submission failed stored the raw error, which GET /v1/deposits/{action_hash} served: the executor's
-- URL, or, in an execution-service 500, its RPC's, whose Alchemy URL holds the API key (exchange #229). They now
-- store a fixed message (api/deposits.go depositUnconfirmedMessage) and the API shows it for any such row; this
-- replaces what the rows already hold, so the database stops keeping it too.
--
-- A rejected row's error is the refusal written for the client and is left alone. Rows already holding the fixed
-- message are not touched, so this is a no-op on a database without such rows and on a second run.
update deposits
set error = 'could not confirm whether the deposit was submitted; retry the same signed request, or check the account before signing a new one'
where status <> 'rejected'
  and coalesce(error, '') <> ''
  and error <> 'could not confirm whether the deposit was submitted; retry the same signed request, or check the account before signing a new one';
