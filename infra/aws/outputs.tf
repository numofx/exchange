output "alb_dns_name" {
  description = "Point the api.numofx.com CNAME here when Gate 5 fires. Rollback is pointing it back at Railway."
  value       = aws_lb.main.dns_name
}

output "api_cutover_record" {
  description = "The DNS change, spelled out."
  value       = "${var.api_domain}  CNAME  ${aws_lb.main.dns_name}   (was: bzcflo7v.up.railway.app)"
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "rds_internal_hostname" {
  description = "What DATABASE_URL actually resolves through — unchanged from Railway."
  value       = aws_route53_record.postgres_internal.name
}

output "ecs_cluster" {
  value = aws_ecs_cluster.main.name
}

output "migrate_task_definition" {
  description = "Run this once before loading data."
  value       = aws_ecs_task_definition.migrate.arn
}

output "secret_backend_in_use" {
  value = var.secret_backend
}

output "manual_secrets_required" {
  description = "Created out of band so they never enter Terraform state."
  value = local.use_ssm ? [
    "/numo/exchange/executor_private_key",
    "/numo/exchange/rpc_url",
    ] : [
    "${var.name}/executor_private_key",
    "${var.name}/rpc_url",
  ]
}
