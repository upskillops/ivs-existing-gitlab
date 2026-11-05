# GitLab object storage. Bucket names are global, so they carry the account ID.

locals {
  # short name => versioned?
  bucket_specs = {
    registry         = false
    artifacts        = false
    lfs              = false
    uploads          = false
    packages         = false
    mr-diffs         = false
    terraform-state  = true
    ci-secure-files  = true
    dependency-proxy = false
    backups          = true # backup-utility archives
    gitaly-backups   = true # Gitaly server-side repository backups
    tmp              = false
  }
  buckets = { for k, v in local.bucket_specs : k => "${local.prefix}-${k}-${local.account_id}" }
}

resource "aws_s3_bucket" "gitlab" {
  for_each = local.buckets

  bucket        = each.value
  force_destroy = false
}

resource "aws_s3_bucket_ownership_controls" "gitlab" {
  for_each = aws_s3_bucket.gitlab
  bucket   = each.value.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "gitlab" {
  for_each = aws_s3_bucket.gitlab
  bucket   = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "gitlab" {
  for_each = aws_s3_bucket.gitlab
  bucket   = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.gitlab.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "gitlab" {
  for_each = { for k, v in aws_s3_bucket.gitlab : k => v if local.bucket_specs[k] }
  bucket   = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "gitlab" {
  for_each = aws_s3_bucket.gitlab
  bucket   = each.value.id

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  dynamic "rule" {
    for_each = each.key == "tmp" ? [1] : []
    content {
      id     = "expire-tmp"
      status = "Enabled"
      filter {}
      expiration {
        days = 7
      }
    }
  }

  dynamic "rule" {
    for_each = contains(["backups", "gitaly-backups"], each.key) ? [1] : []
    content {
      id     = "backup-retention"
      status = "Enabled"
      filter {}
      transition {
        days          = 30
        storage_class = "STANDARD_IA"
      }
      expiration {
        days = var.backup_retention_days
      }
      noncurrent_version_expiration {
        noncurrent_days = 30
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.gitlab]
}

# Deny any non-TLS access.
resource "aws_s3_bucket_policy" "gitlab" {
  for_each = aws_s3_bucket.gitlab
  bucket   = each.value.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [each.value.arn, "${each.value.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.gitlab]
}
