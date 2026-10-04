# The ops box (EC2 i-06107393582d770e3, "numo-ops-amd64"): the feed publisher, mark keeper,
# perp-feeds, perp-keeper and the perp pager run there as systemd units, each reading its
# secrets from SSM at start. The instance and its role predate this stack and were made by hand
# (2026-07-17); the role stays out of band, but what it may READ is adopted here so a grant is a
# reviewed diff rather than a console change nobody can find later.
#
# Every grant is GetParameter/GetParameters on one path. The role holds no signing key of its own:
# the values under these paths are the keys, and that is the whole reason the paths are narrow.
data "aws_iam_role" "ops_box" {
  name = "numo-feed-publisher-role"
}

locals {
  # path under /numo -> the units that read it
  ops_box_ssm_paths = {
    feeds       = "feeds"       # feed publisher, perp-feeds: relayer_key, feed_signer_key, rpc_url, alert_webhook_url
    mark-keeper = "mark-keeper" # mark keeper: mpcvault_token, mpcvault_vault, vault_address
    keeper      = "keeper"      # perp-keeper: keeper_key
    pager       = "pager"       # perp pager: provider, pushover_*/pagerduty_*, heartbeat_url
  }
}

data "aws_iam_policy_document" "ops_box_ssm_read" {
  for_each = local.ops_box_ssm_paths

  statement {
    sid       = each.key == "feeds" ? "ReadNumoFeedParams" : each.key == "mark-keeper" ? "ReadNumoMarkKeeperParams" : null
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["${local.ssm_arn_prefix}/numo/${each.value}/*"]
  }

  # SecureStrings decrypt through SSM's own use of the account's KMS key; the role may not call
  # kms:Decrypt any other way. Carried on the feeds grant, where it has always lived.
  dynamic "statement" {
    for_each = each.key == "feeds" ? [1] : []
    content {
      sid       = "DecryptViaSSM"
      actions   = ["kms:Decrypt"]
      resources = ["*"]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["ssm.${var.region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "ops_box_ssm_read" {
  for_each = local.ops_box_ssm_paths

  name   = "numo-${each.value}-ssm-read"
  role   = data.aws_iam_role.ops_box.id
  policy = data.aws_iam_policy_document.ops_box_ssm_read[each.key].json
}

# The four policies already exist on the role, made by hand. These adopt them into state on the
# next apply instead of creating duplicates; once applied they are no-ops and may be removed.
import {
  for_each = local.ops_box_ssm_paths
  to       = aws_iam_role_policy.ops_box_ssm_read[each.key]
  id       = "numo-feed-publisher-role:numo-${each.value}-ssm-read"
}

# The unified-account cutover (docs/unified-account-cutover.md) moves the spot market-maker's
# inventory from its spot account to a unified one by a script on the box
# (scripts/local-venue/migrate-spot-mm.ts through scripts/ops/run-with-ssm-mm.sh), signing with the
# MM's own key read from SSM in-process. One parameter, not the /numo/exchange/ path. Remove this
# grant once the migration is done: the box has no other business with the MM's key.
data "aws_iam_policy_document" "ops_box_mm_key_read" {
  statement {
    sid       = "ReadMMKeyForUnifiedMigration"
    actions   = ["ssm:GetParameter"]
    resources = ["${local.ssm_arn_prefix}/numo/exchange/mm_private_key"]
  }
}

resource "aws_iam_role_policy" "ops_box_mm_key_read" {
  name   = "numo-mm-key-ssm-read-unified-migration"
  role   = data.aws_iam_role.ops_box.id
  policy = data.aws_iam_policy_document.ops_box_mm_key_read.json
}
