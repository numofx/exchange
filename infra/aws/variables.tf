variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  description = "Prefix for every resource in this stack."
  type        = string
  default     = "numo-exchange"
}

variable "vpc_cidr" {
  # Deliberately not 172.31/16 — that is the account's default VPC, and overlapping
  # ranges make any future peering to it impossible.
  type    = string
  default = "10.20.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "internal_namespace" {
  description = <<-EOT
    Private DNS namespace. Kept as railway.internal on purpose: EXECUTOR_URL and
    DATABASE_URL then carry over from Railway byte-identical, so the cutover changes
    where things run without changing what they are configured to talk to.
  EOT
  type        = string
  default     = "railway.internal"
}

variable "db_instance_class" {
  # 29 MB of data and a paused venue. Right-size up when flow returns, not before.
  type    = string
  default = "db.t4g.micro"
}

variable "db_multi_az" {
  description = "Off for cutover; flip to true once spot has been quoting long enough to care."
  type        = bool
  default     = false
}

variable "api_domain" {
  type    = string
  default = "api.numofx.com"
}

variable "acm_certificate_arn" {
  description = "Existing ACM cert for api_domain in var.region. Must be ISSUED before the ALB applies."
  type        = string
}

variable "image_markets" {
  description = "ECR image URI for the Go binary (serves both api and matcher modes)."
  type        = string
}

variable "image_execution" {
  description = "ECR image URI for services/execution."
  type        = string
}

variable "secret_backend" {
  description = <<-EOT
    Where task secrets are read from. "ssm" matches the convention already in this
    account (/numo/feeds/*, /numo/mark-keeper/* as SecureString) and is the boring
    choice; "secretsmanager" costs more and buys rotation this stack does not use yet.
  EOT
  type        = string
  default     = "ssm"

  validation {
    condition     = contains(["ssm", "secretsmanager"], var.secret_backend)
    error_message = "secret_backend must be \"ssm\" or \"secretsmanager\"."
  }
}

variable "chain_id" {
  type    = string
  default = "8453"
}

variable "matching_address" {
  type    = string
  default = "0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191"
}

variable "trade_module_address" {
  type    = string
  default = "0x44813aD30b2fFC1bB2871Eed9b19F63c8196eD1c"
}

variable "cngn_spot_asset_address" {
  # Losing this silently disables the only market. The boot guard turns that into a
  # crash; keeping it in Terraform keeps it from being lost in the first place.
  type    = string
  default = "0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493"
}

variable "matcher_poll_interval" {
  type    = string
  default = "250ms"
}
