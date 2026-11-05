output "gitlab_url" {
  value = "https://gitlab.${var.domain}"
}

output "gitlab_dns_target" {
  description = "Point gitlab./registry./kas.<domain> (CNAME) at this load balancer hostname."
  value       = "kubectl -n ${var.gitlab_namespace} get svc -l gateway.envoyproxy.io/owning-gateway-name=gitlab-gw -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'"
}

output "root_password_command" {
  value = "kubectl -n ${var.gitlab_namespace} get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d"
}

output "postgres" {
  value = {
    host     = aws_db_instance.gitlab.address
    database = "gitlabhq_production"
    username = "gitlab"
    multi_az = var.db_multi_az
  }
}

output "redis_host" {
  value = aws_elasticache_replication_group.gitlab.primary_endpoint_address
}

output "buckets" {
  value = local.buckets
}

output "secrets_manager" {
  value = {
    external_services = aws_secretsmanager_secret.services.name
    rails_secret      = aws_secretsmanager_secret.rails.name
  }
}

output "gitlab_iam_role_arn" {
  value = aws_iam_role.gitlab.arn
}
