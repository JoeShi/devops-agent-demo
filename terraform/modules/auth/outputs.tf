data "aws_region" "current" {}

output "oidc_client_id" {
  value = aws_cognito_user_pool_client.outline.id
}

output "oidc_client_secret" {
  value     = aws_cognito_user_pool_client.outline.client_secret
  sensitive = true
}

output "oidc_auth_uri" {
  value = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${data.aws_region.current.name}.amazoncognito.com/oauth2/authorize"
}

output "oidc_token_uri" {
  value = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${data.aws_region.current.name}.amazoncognito.com/oauth2/token"
}

output "oidc_userinfo_uri" {
  value = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${data.aws_region.current.name}.amazoncognito.com/oauth2/userInfo"
}

output "oidc_logout_uri" {
  value = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${data.aws_region.current.name}.amazoncognito.com/logout"
}

output "user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "grafana_client_id" {
  value = aws_cognito_user_pool_client.grafana.id
}

output "grafana_client_secret" {
  value     = aws_cognito_user_pool_client.grafana.client_secret
  sensitive = true
}
