# Secret storage. The account already keeps SecureStrings at /numo/<workload>/<key>
# for the feed publisher and mark keeper, so this stack extends that convention by
# default rather than introducing a second store. Set secret_backend to
# "secretsmanager" if rotation becomes a requirement — the task definitions read
# whichever ARN this file hands them, so nothing downstream changes.

locals {
  use_ssm = var.secret_backend == "ssm"

  # Written by Terraform because the password is generated here. The executor key is
  # NOT: it is placed out of band (see below) and only referenced.
  database_url = "postgresql://${aws_db_instance.main.username}:${random_password.db.result}@postgres.${var.internal_namespace}:5432/${aws_db_instance.main.db_name}"
}

# ------------------------------------------------------------------ SSM backend

resource "aws_ssm_parameter" "database_url" {
  count = local.use_ssm ? 1 : 0

  name  = "/numo/exchange/database_url"
  type  = "SecureString"
  value = local.database_url
  tier  = "Standard"
}

# The executor private key and the RPC URL (which carries an Alchemy API key) are
# placed out of band and referenced by ARN only:
#
#   (the executor no longer has a stored key: it signs through KMS, see aws_kms_key.executor)
#   aws ssm put-parameter --name /numo/exchange/rpc_url \
#     --type SecureString --value 0x... --profile numo
#
# Their ARNs are CONSTRUCTED here rather than resolved through a
# `data "aws_ssm_parameter"` block, and that distinction is the whole point: a data
# source fetches the decrypted value and Terraform persists every attribute it
# fetched into terraform.tfstate. Reading the parameter to obtain its ARN would put
# the key in state just as surely as declaring it in a variable would.
#
# The cost is that a missing parameter is no longer caught at plan time; it surfaces
# when ECS cannot start the task. preflight.sh checks for both before a cutover.
data "aws_caller_identity" "current" {}

locals {
  ssm_arn_prefix = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter"
}

# -------------------------------------------------------- Secrets Manager backend

resource "aws_secretsmanager_secret" "database_url" {
  count                   = local.use_ssm ? 0 : 1
  name                    = "${var.name}/database_url"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "database_url" {
  count         = local.use_ssm ? 0 : 1
  secret_id     = aws_secretsmanager_secret.database_url[0].id
  secret_string = local.database_url
}


data "aws_secretsmanager_secret" "rpc_url" {
  count = local.use_ssm ? 0 : 1
  name  = "${var.name}/rpc_url"
}

data "aws_secretsmanager_secret" "mm_private_key" {
  count = local.use_ssm ? 0 : 1
  name  = "${var.name}/mm_private_key"
}

data "aws_secretsmanager_secret" "mm_rpc_url" {
  count = local.use_ssm ? 0 : 1
  name  = "${var.name}/mm_rpc_url"
}

# ------------------------------------------------------------------- resolved ARNs

locals {
  secret_arns = {
    database_url = local.use_ssm ? aws_ssm_parameter.database_url[0].arn : aws_secretsmanager_secret.database_url[0].arn
    rpc_url      = local.use_ssm ? "${local.ssm_arn_prefix}/numo/exchange/rpc_url" : data.aws_secretsmanager_secret.rpc_url[0].arn

    # The market maker signs as 0x3448ac0A…CB47B — a different key from the executor,
    # and it reaches a different RPC endpoint. Reusing rpc_url here would silently
    # repoint it at the executor's provider.
    mm_private_key = local.use_ssm ? "${local.ssm_arn_prefix}/numo/exchange/mm_private_key" : data.aws_secretsmanager_secret.mm_private_key[0].arn
    mm_rpc_url     = local.use_ssm ? "${local.ssm_arn_prefix}/numo/exchange/mm_rpc_url" : data.aws_secretsmanager_secret.mm_rpc_url[0].arn

    # Under /numo/feeds rather than /numo/exchange because it is the same Slack webhook the ops-box
    # alert timers already post to — one channel for anything that halts the venue, whether the
    # sender is a systemd timer or a container. Adding it here is what grants the execution role
    # read access: the IAM policy in ecs.tf scopes to values(local.secret_arns).
    alert_webhook_url = "${local.ssm_arn_prefix}/numo/feeds/alert_webhook_url"
  }
}

# ----------------------------------------------------------- executor signing key
#
# The executor settles every trade and every signed withdrawal. Held as a KMS key rather than a
# secret so the private key never exists outside KMS: not in the task definition, not in the
# process, not in a secret anyone with read access can print. It replaced a SecureString holding the
# raw key, which was deleted on 2026-09-16 once this key's address was authorised and the old one
# revoked on chain.
#
# Creating the key does NOT authorise it. Matching gates settlement on tradeExecutors[msg.sender],
# an owner-only mapping, so the new address must be added with setTradeExecutor and the old one
# retired deliberately, after the new key is proven to settle.
resource "aws_kms_key" "executor" {
  count                    = var.executor_kms_enabled ? 1 : 0
  description              = "${var.name} trade executor signing key (secp256k1)"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_SECG_P256K1"
  # Signing keys are not recoverable once deleted and this one is an on-chain identity: retiring it
  # means a setTradeExecutor call, not a terraform destroy.
  deletion_window_in_days = 30
  enable_key_rotation     = false
  # Terraform must never be able to delete this: the venue settles every trade and every
  # withdrawal with this key, and Matching gates settlement on its address.
  # Retiring it is a deliberate act (sweep the balance, re-point what signs), which means
  # removing this block first -- not a flag someone forgot on a routine plan.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "executor" {
  count         = var.executor_kms_enabled ? 1 : 0
  name          = "alias/${var.name}-executor"
  target_key_id = aws_kms_key.executor[0].key_id
}

# Scoped to this one key by ARN, and attached to the TASK role (the container's own identity),
# not the execution role that only pulls secrets at startup. Sign and GetPublicKey only: the task
# can use the key and read its address, and can neither export, schedule deletion, nor re-policy it.
data "aws_iam_policy_document" "executor_kms_sign" {
  count = var.executor_kms_enabled ? 1 : 0
  statement {
    actions   = ["kms:Sign", "kms:GetPublicKey"]
    resources = [aws_kms_key.executor[0].arn]
  }
}

resource "aws_iam_role_policy" "executor_kms_sign" {
  count  = var.executor_kms_enabled ? 1 : 0
  name   = "executor-kms-sign"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.executor_kms_sign[0].json
}

# Working capital for the cNGN rebalance. The market maker's flow is one-directional -- it sells
# cNGN for USDC -- so without a routine that buys cNGN back the bid side eventually goes dark.
# HyperFX fills that swap same-chain on Base against the identical cNGN the venue settles
# (0x46C85152bFe9f96829aA94755D9f915F9B10EF5F), so the round trip never leaves the chain.
#
# The address this key derives to needs ETH for gas and its own USDC allowance to the gateway
# before it can swap. Neither is terraform's to give it.
resource "aws_kms_key" "rebalance" {
  count                    = var.rebalance_kms_enabled ? 1 : 0
  description              = "${var.name} cNGN rebalance signing key (secp256k1)"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_SECG_P256K1"
  # Same reasoning as the executor key: a signing key is an on-chain identity holding value, and
  # deleting it strands whatever it holds. Retiring it means sweeping the balance first.
  deletion_window_in_days = 30
  enable_key_rotation     = false
  # Terraform must never be able to delete this: it holds the rebalance float, and deleting it
  # strands whatever USDC and cNGN sit at its address.
  # Retiring it is a deliberate act (sweep the balance, re-point what signs), which means
  # removing this block first -- not a flag someone forgot on a routine plan.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "rebalance" {
  count         = var.rebalance_kms_enabled ? 1 : 0
  name          = "alias/${var.name}-rebalance"
  target_key_id = aws_kms_key.rebalance[0].key_id
}
