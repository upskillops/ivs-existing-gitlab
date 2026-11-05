# GitLab on an existing EKS cluster: separate database and backups

One Terraform root that reads your **existing** EKS cluster and adds GitLab 19.5 (Helm chart 10.5.0) with a managed data tier and a layered backup strategy.

## What it creates

| Area | Resources |
|---|---|
| Database (separate) | RDS PostgreSQL 17: gp3, KMS, SSL enforced, PITR, Performance Insights, deletion protection, `db_multi_az` switch |
| Cache (separate) | ElastiCache Redis 7.1: TLS + AUTH, KMS, daily snapshots, `redis_replica` switch for automatic failover |
| Object storage | 12 S3 buckets: SSE-KMS, TLS-only, public access blocked, lifecycle rules |
| Access | IAM role for GitLab's service account (IRSA). No static AWS keys |
| Capacity | Optional dedicated node group `workload=gitlab` (`create_node_group`) |
| GitLab | Namespace, service account, secrets, a Gitaly StorageClass, and the Helm release with Envoy Gateway behind an NLB and Let's Encrypt certificates |

## Backup strategy

| # | Layer | Schedule | Stored in | Retention |
|---|---|---|---|---|
| 1 | `backup-utility` CronJob: database dump, uploads, artifacts, LFS, packages, … | `backup_schedule` (03:30 IST) | S3 `…-backups` (versioned, moved to IA after 30 days) | `backup_retention_days` (90) |
| 2 | Gitaly server-side repository backups (run by the same job) | nightly | S3 `…-gitaly-backups` | 90 days |
| 3 | EBS snapshots of the Gitaly volume (AWS DLM) | daily 03:00 IST | EBS snapshots | `gitaly_snapshot_retention` (14) |
| 4 | RDS automated backups + point-in-time recovery | continuous | RDS | `db_backup_retention_days` (14) |
| 5 | ElastiCache snapshots | daily | ElastiCache | 7 |
| 6 | `gitlab-rails-secret` (GitLab's encryption keys) | every `terraform apply` | Secrets Manager `<prefix>/gitlab-rails-secret` | until deleted |

Safety nets: the Gitaly volume uses `reclaimPolicy: Retain`; RDS has deletion protection and takes a final snapshot.

## Prerequisites on the existing cluster

- The **IAM OIDC provider** is registered for the cluster (needed for IRSA).
- The **EBS CSI driver** is installed (it provisions the Gitaly volume).
- The **AWS Load Balancer Controller** is installed (it provisions the NLB).
- **cert-manager:** if it's already installed, set `install_cert_manager = false`.
- **DNS:** either external-dns for your domain (`external_dns = true`), or create the CNAMEs yourself from the `gitlab_dns_target` output.
- Your Terraform identity can call `eks get-token` and is cluster-admin.
- RDS/Redis must be reachable from the pods. By default the cluster security group is allowed. If your nodes use other security groups, add them to `client_security_group_ids`; for custom pod networking, add CIDRs to `client_cidrs`.

## Deploy

```bash
cp envs/prod.tfvars.example envs/prod.tfvars              # cluster name, subnets, domain, email
cp envs/prod.backend.hcl.example envs/prod.backend.hcl    # your state bucket
terraform init -backend-config=envs/prod.backend.hcl
terraform plan  -var-file=envs/prod.tfvars -out=prod.tfplan
terraform apply prod.tfplan                                # ~25-40 min (RDS + GitLab)

$(terraform output -raw gitlab_dns_target)                 # NLB hostname -> CNAME gitlab./registry./kas.
$(terraform output -raw root_password_command); echo        # root password
```

## Verify the backups once after install

```bash
kubectl -n gitlab exec deploy/gitlab-toolbox -- backup-utility --s3tool awscli --repositories-server-side
aws s3 ls s3://$(terraform output -json buckets | jq -r '.backups')/
aws s3 ls s3://$(terraform output -json buckets | jq -r '."gitaly-backups"')/ --recursive | head
```

## Restore (outline)

1. Run `terraform apply` with the same variables, then put `gitlab-rails-secret` back from Secrets Manager before GitLab starts.
2. Scale webservice and sidekiq to 0.
3. Run `kubectl -n gitlab exec deploy/gitlab-toolbox -- backup-utility --restore -t <timestamp> --s3tool awscli --repositories-server-side`.
4. Scale webservice and sidekiq back up.

For a Gitaly-only recovery, restore the latest DLM snapshot to a volume and bind it to the Gitaly PVC. For the database, use RDS point-in-time restore.

## Cost (ap-south-1, on-demand, defaults)

| Item | Per month |
|---|---|
| 2 × m7g.xlarge node group | ~$170 |
| RDS db.m7g.large Single-AZ + 100 GB | ~$188 (Multi-AZ: ~$376) |
| ElastiCache cache.m7g.large | ~$120 (with replica: ~$239) |
| Gitaly 200 GB gp3, NLB, S3, snapshots | ~$100 |
| **Total** | **~$580** (HA database: ~$890) |
