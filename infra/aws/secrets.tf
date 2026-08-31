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

# The executor private key is deliberately not defined in Terraform — putting it in
# a variable puts it in state. Create it once by hand, then let this data source
# fail loudly if it is missing:
#
#   aws ssm put-parameter --name /numo/exchange/executor_private_key \
#     --type SecureString --value 0x... --profile numo
#
data "aws_ssm_parameter" "executor_key" {
  count = local.use_ssm ? 1 : 0
  name  = "/numo/exchange/executor_private_key"
}

data "aws_ssm_parameter" "rpc_url" {
  count = local.use_ssm ? 1 : 0
  name  = "/numo/exchange/rpc_url"
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

data "aws_secretsmanager_secret" "executor_key" {
  count = local.use_ssm ? 0 : 1
  name  = "${var.name}/executor_private_key"
}

data "aws_secretsmanager_secret" "rpc_url" {
  count = local.use_ssm ? 0 : 1
  name  = "${var.name}/rpc_url"
}

# ------------------------------------------------------------------- resolved ARNs

locals {
  secret_arns = {
    database_url = local.use_ssm ? aws_ssm_parameter.database_url[0].arn : aws_secretsmanager_secret.database_url[0].arn
    executor_key = local.use_ssm ? data.aws_ssm_parameter.executor_key[0].arn : data.aws_secretsmanager_secret.executor_key[0].arn
    rpc_url      = local.use_ssm ? data.aws_ssm_parameter.rpc_url[0].arn : data.aws_secretsmanager_secret.rpc_url[0].arn
  }
}
