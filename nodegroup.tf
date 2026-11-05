# Optional dedicated node group so GitLab does not compete with your applications.
# Pods are pinned to it with the workload=gitlab label.

resource "aws_iam_role" "nodes" {
  count = var.create_node_group ? 1 : 0
  name  = "${local.prefix}-nodes"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "nodes" {
  for_each = var.create_node_group ? toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]) : toset([])
  role       = aws_iam_role.nodes[0].name
  policy_arn = each.value
}

resource "aws_eks_node_group" "gitlab" {
  count = var.create_node_group ? 1 : 0

  cluster_name    = var.cluster_name
  node_group_name = "${local.prefix}-gitlab"
  node_role_arn   = aws_iam_role.nodes[0].arn
  subnet_ids      = var.private_subnet_ids
  ami_type        = var.node_group.ami_type
  instance_types  = var.node_group.instance_types
  disk_size       = var.node_group.disk_gb

  scaling_config {
    min_size     = var.node_group.min_size
    max_size     = var.node_group.max_size
    desired_size = var.node_group.desired_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = { workload = "gitlab" }

  depends_on = [aws_iam_role_policy_attachment.nodes]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size] # managed by the cluster autoscaler, if any
  }
}
