# --- Grafana Service Account Token (for AWS DevOps Agent integration) ---
# Grafana does not expose service account tokens via Helm values, so we
# provision the token via the Grafana HTTP API using a null_resource after
# the Helm release is deployed.  The token value is stored in AWS Secrets
# Manager so that the integration module can read it as a data source.

resource "aws_secretsmanager_secret" "grafana_sa_token" {
  name                    = "grafana-devops-agent-token"
  description             = "Grafana service account access token for AWS DevOps Agent integration"
  recovery_window_in_days = 0
}

resource "null_resource" "grafana_sa_token" {
  depends_on = [helm_release.kube_prometheus_stack]

  triggers = {
    grafana_host = var.grafana_host
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -e
      GRAFANA_URL="https://${var.grafana_host}"
      ADMIN_PASS="${var.grafana_admin_password}"

      # Create service account
      SA_RESPONSE=$(curl -sf -X POST "$GRAFANA_URL/api/serviceaccounts" \
        -u "admin:$ADMIN_PASS" \
        -H "Content-Type: application/json" \
        -d '{"name":"devops-agent","role":"Viewer"}')
      SA_ID=$(echo "$SA_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

      # Create token for the service account
      TOKEN_RESPONSE=$(curl -sf -X POST "$GRAFANA_URL/api/serviceaccounts/$SA_ID/tokens" \
        -u "admin:$ADMIN_PASS" \
        -H "Content-Type: application/json" \
        -d '{"name":"devops-agent-token"}')
      TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])")

      # Store token in Secrets Manager
      aws secretsmanager put-secret-value \
        --secret-id "${aws_secretsmanager_secret.grafana_sa_token.arn}" \
        --secret-string "$TOKEN"
    EOT
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "72.6.2"
  namespace        = "monitoring"
  create_namespace = true

  set {
    name  = "grafana.enabled"
    value = "true"
  }

  set_sensitive {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }

  set_sensitive {
    name  = "grafana.grafana\\.ini.auth\\.generic_oauth.client_secret"
    value = var.grafana_oauth_client_secret
  }

  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  set {
    name  = "alertmanager.enabled"
    value = "true"
  }

  values = [
    yamlencode({
      # Disable monitoring for EKS-managed control plane components
      # (not accessible on managed EKS, causes false-positive alerts)
      kubeScheduler = {
        enabled = false
      }
      kubeControllerManager = {
        enabled = false
      }
      # Suppress KubeVersionMismatch — expected on EKS with mixed component versions
      kubernetesServiceMonitors = {
        additionalRulesOverrides = {}
      }
      defaultRules = {
        disabled = {
          KubeVersionMismatch = true
        }
      }
      alertmanager = {
        serviceAccount = {
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.alertmanager.arn
          }
        }
        config = {
          route = {
            receiver        = "sns-feishu"
            group_by        = ["alertname", "namespace"]
            group_wait      = "30s"
            group_interval  = "5m"
            repeat_interval = "4h"
            routes = [{
              receiver = "null"
              matchers = ["alertname = Watchdog"]
            }]
          }
          receivers = [
            {
              name = "sns-feishu"
              sns_configs = [{
                topic_arn     = var.alertmanager_sns_topic_arn
                send_resolved = true
                sigv4 = {
                  region = "us-east-1"
                }
              }]
            },
            {
              name = "null"
            }
          ]
        }
      }
      prometheus = {
        prometheusSpec = {
          resources = {
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "2"
              memory = "3Gi"
            }
          }
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "gp2"
                accessModes      = ["ReadWriteOnce"]
                resources = {
                  requests = {
                    storage = "50Gi"
                  }
                }
              }
            }
          }
          retention = "15d"
        }
      }
      grafana = {
        plugins = ["grafana-opensearch-datasource"]
        sidecar = {
          dashboards = {
            enabled = true
            label   = "grafana_dashboard"
          }
        }
        serviceAccount = {
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.grafana.arn
          }
        }
        ingress = {
          enabled          = true
          ingressClassName = "alb"
          hosts            = [var.grafana_host]
          annotations = var.grafana_certificate_arn != "" ? {
            "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
            "alb.ingress.kubernetes.io/target-type"     = "ip"
            "alb.ingress.kubernetes.io/listen-ports"    = "[{\"HTTPS\":443}]"
            "alb.ingress.kubernetes.io/certificate-arn" = var.grafana_certificate_arn
            "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
            "alb.ingress.kubernetes.io/healthcheck-path" = "/api/health"
            "alb.ingress.kubernetes.io/group.name"      = "outline"
          } : {}
        }
        "grafana.ini" = merge(
          {
            server = var.grafana_root_url != "" ? {
              root_url = var.grafana_root_url
              domain   = var.grafana_host
            } : {}
            users = {
              allow_sign_up        = false
              auto_assign_org      = true
              auto_assign_org_role = "Viewer"
            }
          },
          var.grafana_oauth_enabled ? {
            "auth.generic_oauth" = {
              enabled               = true
              name                  = "Amazon Cognito"
              client_id             = var.grafana_oauth_client_id
              scopes                = "openid profile email"
              auth_url              = var.grafana_oauth_auth_url
              token_url             = var.grafana_oauth_token_url
              api_url               = var.grafana_oauth_api_url
              role_attribute_strict = false
              allow_sign_up         = true
              auto_login            = false
            }
          } : {}
        )
        assertNoLeakedSecrets = false
        additionalDataSources = [
          {
            name      = "OpenSearch"
            type      = "grafana-opensearch-datasource"
            url       = "https://${var.opensearch_endpoint}"
            access    = "proxy"
            isDefault = false
            basicAuth = true
            basicAuthUser = "admin"
            jsonData = {
              database        = "outline-logs-*"
              version         = "2.11.0"
              timeField       = "@timestamp"
              logLevelField   = "level"
              logMessageField = "log"
            }
            secureJsonData = {
              basicAuthPassword = var.opensearch_master_password
            }
          },
          {
            name      = "OpenSearch-K8s"
            type      = "grafana-opensearch-datasource"
            url       = "https://${var.opensearch_endpoint}"
            access    = "proxy"
            isDefault = false
            basicAuth = true
            basicAuthUser = "admin"
            jsonData = {
              database        = "k8s-logs-*"
              version         = "2.11.0"
              timeField       = "@timestamp"
              logLevelField   = "level"
              logMessageField = "log"
            }
            secureJsonData = {
              basicAuthPassword = var.opensearch_master_password
            }
          },
          {
            name      = "CloudWatch"
            type      = "cloudwatch"
            access    = "proxy"
            isDefault = false
            jsonData = {
              authType      = "default"
              defaultRegion = "us-east-1"
            }
          }
        ]
      }
    })
  ]
}

# --- IRSA: Grafana → CloudWatch (read-only) ---

resource "aws_iam_role" "grafana" {
  name = "${var.eks_cluster_name}-grafana-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_issuer_host}:sub" = "system:serviceaccount:monitoring:kube-prometheus-stack-grafana"
          "${var.oidc_issuer_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "grafana_cloudwatch" {
  name = "cloudwatch-read"
  role = aws_iam_role.grafana.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarmsForMetric",
          "cloudwatch:DescribeAlarmHistory",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "cloudwatch:GetInsightRuleReport",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:GetLogGroupFields",
          "logs:StartQuery",
          "logs:StopQuery",
          "logs:GetQueryResults",
          "logs:GetLogEvents",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeRegions",
          "tag:GetResources",
        ]
        Resource = "*"
      },
    ]
  })
}

# --- IRSA: Alertmanager → SNS ---

resource "aws_iam_role" "alertmanager" {
  name  = "${var.eks_cluster_name}-alertmanager-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_issuer_host}:sub" = "system:serviceaccount:monitoring:kube-prometheus-stack-alertmanager"
          "${var.oidc_issuer_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "alertmanager_sns" {
  name  = "sns-publish"
  role  = aws_iam_role.alertmanager.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sns:Publish"
      Resource = var.alertmanager_sns_topic_arn
    }]
  })
}

# --- IRSA: Fluent Bit → OpenSearch (SigV4) ---

resource "aws_iam_role" "fluent_bit" {
  name = "${var.eks_cluster_name}-fluent-bit-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_issuer_host}:sub" = "system:serviceaccount:monitoring:aws-for-fluent-bit"
          "${var.oidc_issuer_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "fluent_bit_opensearch" {
  name = "opensearch-access"
  role = aws_iam_role.fluent_bit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["es:ESHttp*"]
      Resource = "${var.opensearch_domain_arn}/*"
    }]
  })
}

resource "helm_release" "fluent_bit" {
  name       = "aws-for-fluent-bit"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  namespace  = "monitoring"

  depends_on = [helm_release.kube_prometheus_stack]

  values = [
    yamlencode({
      serviceAccount = {
        create = true
        name   = "aws-for-fluent-bit"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.fluent_bit.arn
        }
      }
      # Disable built-in outputs — we use custom config for namespace-based routing
      opensearch = {
        enabled = false
      }
      cloudWatch = {
        enabled = false
      }
      firehose = {
        enabled = false
      }
      kinesis = {
        enabled = false
      }
      additionalFilters = <<-EOF
        [FILTER]
            Name    rewrite_tag
            Match   kube.*
            Rule    $kubernetes['namespace_name'] ^(outline)$ outline.$TAG false
      EOF
      additionalOutputs = <<-EOF
        [OUTPUT]
            Name            opensearch
            Match           outline.*
            Host            ${var.opensearch_endpoint}
            Port            443
            TLS             On
            AWS_Auth        On
            AWS_Region      us-east-1
            Logstash_Format On
            Logstash_Prefix outline-logs
            Suppress_Type_Name On

        [OUTPUT]
            Name            opensearch
            Match           kube.*
            Host            ${var.opensearch_endpoint}
            Port            443
            TLS             On
            AWS_Auth        On
            AWS_Region      us-east-1
            Logstash_Format On
            Logstash_Prefix k8s-logs
            Suppress_Type_Name On
      EOF
    })
  ]
}

# --- Grafana Dashboard (auto-loaded by sidecar) ---

resource "kubernetes_config_map" "grafana_dashboard_outline" {
  metadata {
    name      = "grafana-dashboard-outline"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "outline-app-overview.json" = file("${path.module}/../../../grafana/dashboards/outline-app-overview.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}