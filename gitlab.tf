locals {
  # Gitaly's EBS volume is AZ-bound: keep the pod in the AZ of the first private subnet.
  gitaly_zone = data.aws_subnet.private[var.private_subnet_ids[0]].availability_zone

  node_selector = var.create_node_group ? { workload = "gitlab" } : {}

  gitlab_values = {
    global = {
      edition = "ee" # Free tier without a license
      hosts = {
        domain = var.domain
        https  = true
      }
      gatewayApi = {
        enabled              = true
        installEnvoy         = true
        configureCertmanager = true
        httpToHttpsRedirect  = true
      }
      ingress = { enabled = false }

      serviceAccount = { enabled = true, create = false, name = local.gitlab_sa }

      psql = {
        host     = aws_db_instance.gitlab.address
        port     = 5432
        database = "gitlabhq_production"
        username = "gitlab"
        password = { secret = "gitlab-postgres", key = "password" }
      }
      redis = {
        host   = aws_elasticache_replication_group.gitlab.primary_endpoint_address
        port   = 6379
        scheme = "rediss"
        auth   = { enabled = true, secret = "gitlab-redis", key = "password" }
      }

      appConfig = {
        object_store = {
          enabled        = true
          proxy_download = true
          connection     = { secret = "gitlab-object-storage", key = "connection" }
        }
        lfs             = { bucket = local.buckets["lfs"] }
        artifacts       = { bucket = local.buckets["artifacts"] }
        uploads         = { bucket = local.buckets["uploads"] }
        packages        = { bucket = local.buckets["packages"] }
        externalDiffs   = { enabled = true, bucket = local.buckets["mr-diffs"] }
        terraformState  = { enabled = true, bucket = local.buckets["terraform-state"] }
        ciSecureFiles   = { enabled = true, bucket = local.buckets["ci-secure-files"] }
        dependencyProxy = { enabled = true, bucket = local.buckets["dependency-proxy"] }
        backups         = { bucket = local.buckets["backups"], tmpBucket = local.buckets["tmp"] }
      }

      nodeSelector = local.node_selector
    }

    installCertmanager = var.install_cert_manager
    certmanager-issuer = { email = var.letsencrypt_email }

    gatewayApiResources = {
      envoy = {
        proxySpec = {
          provider = {
            type = "Kubernetes"
            kubernetes = {
              envoyDeployment = { replicas = 2 }
              envoyService = {
                type                  = "LoadBalancer"
                externalTrafficPolicy = "Cluster"
                annotations = merge({
                  "service.beta.kubernetes.io/aws-load-balancer-type"                              = "external"
                  "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"                   = "ip"
                  "service.beta.kubernetes.io/aws-load-balancer-scheme"                            = "internet-facing"
                  "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
                  }, var.external_dns ? {
                  "external-dns.alpha.kubernetes.io/hostname" = "gitlab.${var.domain},registry.${var.domain},kas.${var.domain}"
                } : {})
              }
            }
          }
        }
      }
    }

    prometheus    = { install = false }
    gitlab-runner = { install = false }

    registry = {
      storage = { secret = "gitlab-registry-storage", key = "config" }
      hpa     = { minReplicas = var.gitlab_replicas.registry, maxReplicas = max(var.gitlab_replicas.registry, 4) }
    }

    gitlab = {
      webservice = {
        minReplicas = var.gitlab_replicas.webservice
        maxReplicas = max(var.gitlab_replicas.webservice, 4)
        resources   = { requests = { cpu = "1", memory = "2.5G" } }
      }
      sidekiq = {
        minReplicas = var.gitlab_replicas.sidekiq
        maxReplicas = max(var.gitlab_replicas.sidekiq, 4)
        resources   = { requests = { cpu = "500m", memory = "2G" } }
      }
      gitlab-shell = {
        minReplicas = var.gitlab_replicas.shell
        maxReplicas = max(var.gitlab_replicas.shell, 4)
      }
      gitaly = {
        nodeSelector = merge(local.node_selector, { "topology.kubernetes.io/zone" = local.gitaly_zone })
        persistence = {
          enabled      = true
          storageClass = kubernetes_storage_class_v1.gitaly.metadata[0].name
          size         = "${var.gitaly_disk_gb}Gi"
        }
        resources = {
          requests = { cpu = "1", memory = "4Gi" }
          limits   = { memory = "12Gi" }
        }
        backup = { goCloudUrl = "s3://${local.buckets["gitaly-backups"]}?region=${var.region}&awssdk=v2" }
      }
      toolbox = {
        backups = {
          cron = {
            enabled  = true
            schedule = var.backup_schedule
            # awscli uses the IRSA role (s3cmd cannot); repositories via Gitaly server-side backup
            extraArgs = "--s3tool awscli --repositories-server-side"
            persistence = {
              enabled                   = true
              useGenericEphemeralVolume = true
              size                      = "100Gi"
            }
            resources = { requests = { cpu = "500m", memory = "1Gi" } }
          }
          objectStorage = { backend = "s3" }
        }
      }
    }
  }
}

resource "kubernetes_namespace_v1" "gitlab" {
  metadata {
    name = var.gitlab_namespace
  }
}

resource "kubernetes_service_account_v1" "gitlab" {
  metadata {
    name        = local.gitlab_sa
    namespace   = kubernetes_namespace_v1.gitlab.metadata[0].name
    annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.gitlab.arn }
  }
}

resource "kubernetes_secret_v1" "postgres" {
  metadata {
    name      = "gitlab-postgres"
    namespace = kubernetes_namespace_v1.gitlab.metadata[0].name
  }
  data = { password = random_password.db.result }
}

resource "kubernetes_secret_v1" "redis" {
  metadata {
    name      = "gitlab-redis"
    namespace = kubernetes_namespace_v1.gitlab.metadata[0].name
  }
  data = { password = random_password.redis.result }
}

resource "kubernetes_secret_v1" "object_storage" {
  metadata {
    name      = "gitlab-object-storage"
    namespace = kubernetes_namespace_v1.gitlab.metadata[0].name
  }
  data = {
    connection = yamlencode({ provider = "AWS", region = var.region, use_iam_profile = true })
  }
}

resource "kubernetes_secret_v1" "registry_storage" {
  metadata {
    name      = "gitlab-registry-storage"
    namespace = kubernetes_namespace_v1.gitlab.metadata[0].name
  }
  data = {
    config = yamlencode({ s3_v2 = { bucket = local.buckets["registry"], region = var.region } })
  }
}

# Gitaly repositories: Retain on delete, faster gp3, tagged for the daily DLM snapshots.
resource "kubernetes_storage_class_v1" "gitaly" {
  metadata {
    name = "${local.prefix}-gitaly"
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type               = "gp3"
    iops               = "6000"
    throughput         = "250"
    encrypted          = "true" # AWS-managed EBS key: works with any existing EBS CSI driver role
    tagSpecification_1 = "${local.gitaly_snapshot_tag.key}=${local.gitaly_snapshot_tag.value}"
  }
}

resource "helm_release" "gitlab" {
  name       = "gitlab"
  namespace  = kubernetes_namespace_v1.gitlab.metadata[0].name
  repository = "https://charts.gitlab.io"
  chart      = "gitlab"
  version    = var.gitlab_chart_version

  values  = [yamlencode(local.gitlab_values)]
  timeout = 1800
  wait    = true

  depends_on = [
    kubernetes_service_account_v1.gitlab,
    kubernetes_secret_v1.postgres,
    kubernetes_secret_v1.redis,
    kubernetes_secret_v1.object_storage,
    kubernetes_secret_v1.registry_storage,
    aws_eks_node_group.gitlab,
    aws_db_instance.gitlab,
    aws_elasticache_replication_group.gitlab,
  ]
}
