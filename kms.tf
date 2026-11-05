# Customer-managed key for GitLab data at rest: S3, RDS, ElastiCache, Secrets Manager.
resource "aws_kms_key" "gitlab" {
  description             = "${local.prefix} data at rest"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "gitlab" {
  name          = "alias/${local.prefix}"
  target_key_id = aws_kms_key.gitlab.key_id
}
