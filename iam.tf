# GitLab pods (webservice, sidekiq, registry, toolbox, Gitaly backups) reach S3 through IRSA.
locals {
  gitlab_sa = "gitlab-irsa"
}

resource "aws_iam_role" "gitlab" {
  name = "${local.prefix}-gitlab"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:${var.gitlab_namespace}:${local.gitlab_sa}"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "gitlab_s3" {
  name = "s3"
  role = aws_iam_role.gitlab.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Buckets"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
        Resource = [for b in aws_s3_bucket.gitlab : b.arn]
      },
      {
        Sid    = "Objects"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:PutObjectAcl",
          "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts",
        ]
        Resource = [for b in aws_s3_bucket.gitlab : "${b.arn}/*"]
      },
      {
        Sid      = "Kms"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [aws_kms_key.gitlab.arn]
      },
    ]
  })
}
