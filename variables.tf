variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "name" {
  type        = string
  description = "Prefix for the AWS resources created here."
  default     = "gitlab"
}

# ---------------- Existing cluster ----------------
variable "cluster_name" {
  type        = string
  description = "Existing EKS cluster to install GitLab into."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets (2+ AZs) for RDS, ElastiCache and the optional node group. Usually the cluster's node subnets."
}

variable "client_security_group_ids" {
  type        = list(string)
  description = "Extra security groups allowed to reach RDS / Redis (e.g. your node group SGs). The cluster security group is always allowed."
  default     = []
}

variable "client_cidrs" {
  type        = list(string)
  description = "Extra CIDRs allowed to reach RDS / Redis (e.g. the VPC CIDR if pods use custom networking)."
  default     = []
}

# ---------------- Optional dedicated node group ----------------
variable "create_node_group" {
  type        = bool
  description = "Create a dedicated node group for GitLab (recommended unless the cluster has ~8 vCPU / 24 GB spare)."
  default     = true
}

variable "node_group" {
  type = object({
    instance_types = optional(list(string), ["m7g.xlarge"])
    ami_type       = optional(string, "AL2023_ARM_64_STANDARD")
    min_size       = optional(number, 2)
    max_size       = optional(number, 4)
    desired_size   = optional(number, 2)
    disk_gb        = optional(number, 50)
  })
  default = {}
}

# ---------------- PostgreSQL ----------------
variable "db_instance_class" {
  type    = string
  default = "db.m7g.large"
}

variable "db_engine_version" {
  type        = string
  description = "GitLab 19.x requires PostgreSQL 17+."
  default     = "17"
}

variable "db_multi_az" {
  type        = bool
  description = "Standby in a second AZ (automatic failover). Doubles the RDS cost."
  default     = false
}

variable "db_allocated_storage" {
  type    = number
  default = 100
}

variable "db_max_allocated_storage" {
  type    = number
  default = 500
}

variable "db_backup_retention_days" {
  type    = number
  default = 14
}

# ---------------- Redis ----------------
variable "redis_node_type" {
  type    = string
  default = "cache.m7g.large"
}

variable "redis_engine_version" {
  type    = string
  default = "7.1"
}

variable "redis_replica" {
  type        = bool
  description = "Add a replica in another AZ with automatic failover."
  default     = false
}

# ---------------- GitLab ----------------
variable "domain" {
  type        = string
  description = "GitLab base domain: gitlab.<domain>, registry.<domain>, kas.<domain>."
}

variable "letsencrypt_email" {
  type = string
}

variable "gitlab_chart_version" {
  type    = string
  default = "10.5.0"
}

variable "gitlab_namespace" {
  type    = string
  default = "gitlab"
}

variable "install_cert_manager" {
  type        = bool
  description = "Let the GitLab chart install cert-manager. Set false if the cluster already runs it."
  default     = true
}

variable "external_dns" {
  type        = bool
  description = "Annotate the GitLab load balancer for external-dns (if the cluster runs it). Otherwise create the DNS records from the gitlab_dns_target output."
  default     = false
}

variable "gitlab_replicas" {
  type = object({
    webservice = optional(number, 2)
    sidekiq    = optional(number, 1)
    shell      = optional(number, 2)
    registry   = optional(number, 2)
  })
  default = {}
}

variable "gitaly_disk_gb" {
  type    = number
  default = 200
}

# ---------------- Backups ----------------
variable "backup_schedule" {
  type        = string
  description = "Cron (UTC) for the nightly GitLab backup."
  default     = "0 22 * * *" # 03:30 IST
}

variable "backup_retention_days" {
  type    = number
  default = 90
}

variable "gitaly_snapshot_retention" {
  type    = number
  default = 14
}
