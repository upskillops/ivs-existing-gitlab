data "aws_caller_identity" "current" {}

data "aws_subnet" "private" {
  for_each = toset(var.private_subnet_ids)
  id       = each.value
}

# IRSA: the cluster's OIDC provider must already be registered in IAM.
data "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

locals {
  prefix      = "${var.name}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
  vpc_id      = data.aws_eks_cluster.this.vpc_config[0].vpc_id
  cluster_sg  = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  oidc_arn    = data.aws_iam_openid_connect_provider.eks.arn
  oidc_issuer = replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
  client_sgs  = concat([local.cluster_sg], var.client_security_group_ids)
}
