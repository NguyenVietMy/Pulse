terraform {
  backend "s3" {
    bucket         = "pulse-tf-state-520622116399-us-east-1"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-locks"
    profile        = "pulse"
  }

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "pulse"
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

locals {
  project                         = "pulse"
  env                             = "dev"
  domain                          = "pulse-cs.com"
  api_domain                      = "api.pulse-cs.com"
  frontend_url                    = "https://pulse-cs.com"
  private_cidrs                   = ["10.20.10.0/24", "10.20.11.0/24"]
  internal_namespace              = "pulse.local"
  langfuse_host                   = "https://us.cloud.langfuse.com"
  observability_otlp_endpoint     = "https://otlp-gateway-prod-us-east-2.grafana.net/otlp/v1/traces"
  observability_otlp_metrics_url  = "https://otlp-gateway-prod-us-east-2.grafana.net/otlp/v1/metrics"
  observability_otlp_logs_url     = "https://otlp-gateway-prod-us-east-2.grafana.net/otlp/v1/logs"
  observability_service_name      = "pulse-api"
  observability_service_namespace = "pulse"
}

variable "image_tag" {
  type        = string
  description = "Docker image tag to deploy"
  default     = "latest"
}

variable "agent_image_tag" {
  type        = string
  description = "Agent Docker image tag to deploy"
  default     = "latest"
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

# ---------- Cloudflare DNS ----------

data "cloudflare_zone" "this" {
  name = local.domain
}

# ---------- ACM certificate (DNS validation via Cloudflare) ----------

resource "aws_acm_certificate" "api" {
  domain_name       = local.api_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "cloudflare_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.api.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id = data.cloudflare_zone.this.id
  name    = each.value.name
  type    = each.value.type
  content = each.value.value
  ttl     = 60
  proxied = false
}

resource "aws_acm_certificate_validation" "api" {
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for record in cloudflare_record.acm_validation : record.hostname]
}

resource "cloudflare_record" "api" {
  zone_id = data.cloudflare_zone.this.id
  name    = "api"
  type    = "CNAME"
  content = module.ecs_api.alb_dns_name
  ttl     = 60
  proxied = false
}

# ---------- Network ----------

module "network" {
  source        = "../../modules/network"
  project       = local.project
  env           = local.env
  vpc_cidr      = "10.20.0.0/16"
  public_cidrs  = ["10.20.1.0/24", "10.20.2.0/24"]
  private_cidrs = local.private_cidrs
}

# ---------- Service discovery (api <-> agent, private) ----------

# The API calls the agent's /chat and the agent calls back into the API's /internal/context/*, which
# the public listener 404s. Both hops resolve through this namespace, so neither service needs a
# public address to talk to the other.
resource "aws_service_discovery_private_dns_namespace" "internal" {
  name = local.internal_namespace
  vpc  = module.network.vpc_id
}

resource "aws_service_discovery_service" "api" {
  name = "api"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.internal.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  # ECS registers and deregisters task IPs itself; this marks health as externally managed.
  health_check_custom_config {}

  # GetService omits HealthCheckCustomConfig once its only field (failure_threshold) is unset, so
  # the block never lands in state and each plan wants to add it back — and the block is ForceNew.
  # Left alone that replaces both Cloud Map services on every apply, deregistering the running
  # tasks from private DNS. Type=DNS_HTTP on the live service confirms the config did apply; only
  # the read-back is lossy.
  lifecycle {
    ignore_changes = [health_check_custom_config]
  }
}

resource "aws_service_discovery_service" "agent" {
  name = "agent"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.internal.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  # ECS registers and deregisters task IPs itself; this marks health as externally managed.
  health_check_custom_config {}

  # See the note on the api service above: the block is ForceNew and never reads back.
  lifecycle {
    ignore_changes = [health_check_custom_config]
  }
}

# ---------- ECR ----------

module "ecr" {
  source  = "../../modules/ecr"
  project = local.project
  env     = local.env
}

# ---------- Alarms: SNS ----------

resource "aws_sns_topic" "alarms" {
  name = "${local.project}-${local.env}-alarms"
}

resource "aws_sns_topic_subscription" "alarms_email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = "mynv2712@gmail.com"
}

# ---------- ECS API ----------

module "ecs_api" {
  source             = "../../modules/ecs_api"
  project            = local.project
  env                = local.env
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
  container_image    = "${module.ecr.repository_url}:${var.image_tag}"
  container_port     = 8080
  api_domain         = local.api_domain
  frontend_url       = local.frontend_url
  alarm_actions      = [aws_sns_topic.alarms.arn]

  service_registry_arn   = aws_service_discovery_service.api.arn
  internal_ingress_cidrs = local.private_cidrs

  secret_arns = {
    SUPABASE_SESSION_POOLER          = aws_secretsmanager_secret.supabase_session_pooler.arn
    DB_USER                          = aws_secretsmanager_secret.db_user.arn
    DB_PASSWORD                      = aws_secretsmanager_secret.db_password.arn
    OPENAI_API_KEY                   = aws_secretsmanager_secret.openai_api_key.arn
    ANTHROPIC_API_KEY                = aws_secretsmanager_secret.anthropic_api_key.arn
    LANGFUSE_PUBLIC_KEY              = aws_secretsmanager_secret.langfuse_public_key.arn
    LANGFUSE_SECRET_KEY              = aws_secretsmanager_secret.langfuse_secret_key.arn
    QDRANT_URL                       = aws_secretsmanager_secret.qdrant_url.arn
    QDRANT_API_KEY                   = aws_secretsmanager_secret.qdrant_api_key.arn
    GOOGLE_CLIENT_ID                 = aws_secretsmanager_secret.google_client_id.arn
    GOOGLE_CLIENT_SECRET             = aws_secretsmanager_secret.google_client_secret.arn
    GITHUB_APP_ID                    = aws_secretsmanager_secret.github_app_id.arn
    GITHUB_APP_PRIVATE_KEY           = aws_secretsmanager_secret.github_app_private_key.arn
    GITHUB_APP_INSTALL_URL           = aws_secretsmanager_secret.github_app_install_url.arn
    GITHUB_WEBHOOK_SECRET            = aws_secretsmanager_secret.github_webhook_secret.arn
    SLACK_CLIENT_ID                  = aws_secretsmanager_secret.slack_client_id.arn
    SLACK_CLIENT_SECRET              = aws_secretsmanager_secret.slack_client_secret.arn
    SLACK_SIGNING_SECRET             = aws_secretsmanager_secret.slack_signing_secret.arn
    LINEAR_CLIENT_ID                 = aws_secretsmanager_secret.linear_client_id.arn
    LINEAR_CLIENT_SECRET             = aws_secretsmanager_secret.linear_client_secret.arn
    LINEAR_WEBHOOK_SECRET            = aws_secretsmanager_secret.linear_webhook_secret.arn
    OBSERVABILITY_OTLP_AUTHORIZATION = aws_secretsmanager_secret.observability_otlp_authorization.arn
    INTERNAL_TOKEN                   = aws_secretsmanager_secret.internal_token.arn
  }

  extra_environment = {
    QDRANT_ENABLED = "true"
    # Chat is served by the agent since issue 08; without this the client falls back to localhost
    # and every turn returns the degraded "temporarily unavailable" response.
    AGENT_URL = "http://agent.${local.internal_namespace}:8001"
    # langfuse.enabled defaults to false, so the deployed API traced nothing before issue 11.
    LANGFUSE_ENABLED                           = "true"
    LANGFUSE_HOST                              = local.langfuse_host
    OBSERVABILITY_TRACING_ENABLED              = "true"
    OBSERVABILITY_OTLP_ENDPOINT                = local.observability_otlp_endpoint
    OBSERVABILITY_METRICS_ENABLED              = "true"
    OBSERVABILITY_OTLP_METRICS_URL             = local.observability_otlp_metrics_url
    OBSERVABILITY_TRACING_SAMPLING_PROBABILITY = "1.0"
    OBSERVABILITY_LOGS_ENABLED                 = "true"
    OBSERVABILITY_OTLP_LOGS_URL                = local.observability_otlp_logs_url
    OBSERVABILITY_SERVICE_NAME                 = local.observability_service_name
    OBSERVABILITY_SERVICE_NAMESPACE            = local.observability_service_namespace
    OBSERVABILITY_ENVIRONMENT                  = local.env
  }
}

# ---------- ECS Agent ----------

# No load balancer, no target group, no listener rule: the agent is reachable only from the API's
# security group over the private subnets.
module "ecs_agent" {
  source             = "../../modules/ecs_agent"
  project            = local.project
  env                = local.env
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  cluster_id         = module.ecs_api.cluster_id
  cluster_name       = module.ecs_api.cluster_name
  container_image    = "${module.ecr.agent_repository_url}:${var.agent_image_tag}"
  container_port     = 8001
  alarm_actions      = [aws_sns_topic.alarms.arn]

  ingress_security_group_ids = [module.ecs_api.ecs_security_group_id]
  service_registry_arn       = aws_service_discovery_service.agent.arn

  secret_arns = {
    ANTHROPIC_API_KEY   = aws_secretsmanager_secret.anthropic_api_key.arn
    OPENAI_API_KEY      = aws_secretsmanager_secret.openai_api_key.arn
    QDRANT_URL          = aws_secretsmanager_secret.qdrant_url.arn
    QDRANT_API_KEY      = aws_secretsmanager_secret.qdrant_api_key.arn
    INTERNAL_TOKEN      = aws_secretsmanager_secret.internal_token.arn
    LANGFUSE_PUBLIC_KEY = aws_secretsmanager_secret.langfuse_public_key.arn
    LANGFUSE_SECRET_KEY = aws_secretsmanager_secret.langfuse_secret_key.arn
  }

  extra_environment = {
    # Must match the API's Langfuse project, or the two halves of a chat trace split in two.
    LANGFUSE_HOST = local.langfuse_host
    PULSE_API_URL = "http://api.${local.internal_namespace}:8080"

    # Langfuse builds its resource with Resource.create(), which merges OTel's env detector — so
    # this is what names the Python half of a chat trace. Without it those spans export as
    # "unknown_service" while the Java half says "pulse-api", and prod traces can't be filtered
    # by service. The Java side gets the equivalent from its own OTLP config, not from here.
    OTEL_SERVICE_NAME = "pulse-agent"
  }
}

# ---------- HTTPS Listener ----------

resource "aws_lb_listener" "api_https" {
  load_balancer_arn = module.ecs_api.alb_arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.api.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = module.ecs_api.tg_arn
  }
}

# The /internal/** context API (issue 06) serves full resume and profile text by userId with no user
# session. It is for service-to-service calls inside the VPC only, so the public listener refuses it
# outright rather than relying on the shared-secret filter alone.
resource "aws_lb_listener_rule" "block_internal" {
  listener_arn = aws_lb_listener.api_https.arn
  priority     = 1

  condition {
    path_pattern {
      values = ["/internal/*"]
    }
  }

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\":\"Not found\"}"
      status_code  = "404"
    }
  }
}

# ---------- CI/CD: GitHub Actions OIDC ----------

data "aws_caller_identity" "current" {}

# Account-level singleton, shared with other projects in this account (the contentlens-github-actions
# role federates to the same provider). Managing it here would make ./teardown.ps1 delete it and
# silently break their deploys — and creating it again fails with EntityAlreadyExists, which is what
# blocked the issue-11 apply. Read it, do not own it.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "github_actions_deploy" {
  name = "${local.project}-${local.env}-github-actions-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = data.aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:NguyenVietMy/Pulse:ref:refs/heads/main"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "github_actions_deploy" {
  name = "${local.project}-${local.env}-deploy-policy"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = [
          module.ecr.repository_arn,
          module.ecr.agent_repository_arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService",
          "ecs:DescribeServices"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          module.ecs_api.task_exec_role_arn,
          module.ecs_agent.task_exec_role_arn
        ]
      }
    ]
  })
}

# ---------- Secrets Manager ----------

resource "aws_secretsmanager_secret" "supabase_session_pooler" {
  name                    = "pulse/dev/SUPABASE_SESSION_POOLER"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "db_user" {
  name                    = "pulse/dev/DB_USER"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "pulse/dev/DB_PASSWORD"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "openai_api_key" {
  name                    = "pulse/dev/OPENAI_API_KEY"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "anthropic_api_key" {
  name                    = "pulse/dev/ANTHROPIC_API_KEY"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "langfuse_public_key" {
  name                    = "pulse/dev/LANGFUSE_PUBLIC_KEY"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "langfuse_secret_key" {
  name                    = "pulse/dev/LANGFUSE_SECRET_KEY"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "internal_token" {
  name                    = "pulse/dev/INTERNAL_TOKEN"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "qdrant_url" {
  name                    = "pulse/dev/QDRANT_URL"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "qdrant_api_key" {
  name                    = "pulse/dev/QDRANT_API_KEY"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "google_client_id" {
  name                    = "pulse/dev/GOOGLE_CLIENT_ID"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "google_client_secret" {
  name                    = "pulse/dev/GOOGLE_CLIENT_SECRET"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "github_app_id" {
  name                    = "pulse/dev/GITHUB_APP_ID"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "github_app_private_key" {
  name                    = "pulse/dev/GITHUB_APP_PRIVATE_KEY"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "github_app_install_url" {
  name                    = "pulse/dev/GITHUB_APP_INSTALL_URL"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "github_webhook_secret" {
  name                    = "pulse/dev/GITHUB_WEBHOOK_SECRET"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "slack_client_id" {
  name                    = "pulse/dev/SLACK_CLIENT_ID"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "slack_client_secret" {
  name                    = "pulse/dev/SLACK_CLIENT_SECRET"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "slack_signing_secret" {
  name                    = "pulse/dev/SLACK_SIGNING_SECRET"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "linear_client_id" {
  name                    = "pulse/dev/LINEAR_CLIENT_ID"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "linear_client_secret" {
  name                    = "pulse/dev/LINEAR_CLIENT_SECRET"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "linear_webhook_secret" {
  name                    = "pulse/dev/LINEAR_WEBHOOK_SECRET"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "observability_otlp_authorization" {
  name                    = "pulse/dev/OBSERVABILITY_OTLP_AUTHORIZATION"
  recovery_window_in_days = 0
}
