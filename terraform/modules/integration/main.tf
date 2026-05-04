data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  notifier_zip                     = "${path.module}/lambda/feishu_notifier.zip"
  investigation_notifier_zip       = "${path.module}/lambda/investigation_notifier.zip"
  investigation_notifier_build_dir = "${path.module}/lambda/.build/investigation_notifier"
}
# --- Archive: feishu-notifier only ---

data "archive_file" "feishu_notifier" {
  type        = "zip"
  source_file = "${path.module}/lambda/feishu_notifier.py"
  output_path = local.notifier_zip
}

# --- Archive: investigation-notifier with bundled boto3 (for devops-agent service) ---
# Lambda's built-in botocore (as of 2026-04) does not yet include the
# `devops-agent` service model. We vendor a recent boto3 into the zip so the
# Lambda can call get-backlog-task and list-journal-records.

resource "null_resource" "investigation_notifier_deps" {
  triggers = {
    source_hash = filesha256("${path.module}/lambda/investigation_notifier.py")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      rm -rf "${local.investigation_notifier_build_dir}"
      mkdir -p "${local.investigation_notifier_build_dir}"
      cp "${path.module}/lambda/investigation_notifier.py" "${local.investigation_notifier_build_dir}/"
      python3 -m pip install --quiet --target "${local.investigation_notifier_build_dir}" \
        --upgrade 'boto3>=1.42' 'botocore>=1.42'
    EOT
  }
}

data "archive_file" "investigation_notifier" {
  depends_on  = [null_resource.investigation_notifier_deps]
  type        = "zip"
  source_dir  = local.investigation_notifier_build_dir
  output_path = local.investigation_notifier_zip
}

# --- IAM: feishu-notifier (Lambda) ---

resource "aws_iam_role" "notifier" {
  name = "feishu-notifier-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "notifier_basic" {
  role       = aws_iam_role.notifier.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "notifier_eventbridge" {
  name = "eventbridge-access"
  role = aws_iam_role.notifier.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:event-bus/default"
      },
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          aws_secretsmanager_secret.github_token.arn,
          "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:outline/feishu-bot-*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["aidevops:ListJournalRecords", "aidevops:GetBacklogTask"]
        Resource = "arn:aws:aidevops:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:agentspace/${var.devops_agent_space_id}"
      },
    ]
  })
}

# --- Secrets Manager: GitHub token ---

resource "aws_secretsmanager_secret" "github_token" {
  name = "outline/github-token"
}

# --- Lambda: feishu-notifier (EventBridge → 飞书 Webhook 单向通知) ---

resource "aws_lambda_function" "feishu_notifier" {
  function_name    = "feishu-notifier"
  role             = aws_iam_role.notifier.arn
  handler          = "feishu_notifier.handler"
  runtime          = "python3.12"
  filename         = local.notifier_zip
  source_code_hash = data.archive_file.feishu_notifier.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      FEISHU_BOT_SECRET   = "outline/feishu-bot"
      FEISHU_CHAT_ID      = var.feishu_chat_id
      GITHUB_TOKEN_SECRET = aws_secretsmanager_secret.github_token.arn
      GITHUB_REPO         = var.github_repo
    }
  }
}

# --- EventBridge: DevOps Agent → feishu-notifier ---

resource "aws_cloudwatch_event_rule" "devops_agent" {
  name = "devops-agent-to-feishu"
  event_pattern = jsonencode({
    source      = ["aws.devopsagent"]
    detail-type = ["DevOps Agent Investigation Update"]
  })
}

resource "aws_cloudwatch_event_target" "devops_agent" {
  rule = aws_cloudwatch_event_rule.devops_agent.name
  arn  = aws_lambda_function.feishu_notifier.arn
}

resource "aws_lambda_permission" "devops_agent" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.feishu_notifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.devops_agent.arn
}

# --- EventBridge: Grafana Alerts → feishu-notifier ---

resource "aws_cloudwatch_event_rule" "grafana_alerts" {
  name = "grafana-alerts-to-feishu"
  event_pattern = jsonencode({
    source      = ["aws.grafana"]
    detail-type = ["Grafana Alert"]
  })
}

resource "aws_cloudwatch_event_target" "grafana_alerts" {
  rule = aws_cloudwatch_event_rule.grafana_alerts.name
  arn  = aws_lambda_function.feishu_notifier.arn
}

resource "aws_lambda_permission" "grafana_alerts" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.feishu_notifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.grafana_alerts.arn
}

# --- SNS: Grafana Alertmanager → feishu-notifier ---

resource "aws_sns_topic" "grafana_alerts" {
  name = "grafana-alerts-to-notifier"
}

resource "aws_sns_topic_subscription" "feishu_notifier" {
  topic_arn = aws_sns_topic.grafana_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.feishu_notifier.arn
}

resource "aws_lambda_permission" "sns" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.feishu_notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.grafana_alerts.arn
}

# --- IRSA: feishu-bot EKS Pod → aidevops Chat API ---
# Bot 以长连接模式运行在 EKS 上，通过 IRSA 获取调用 DevOps Agent 的权限。

resource "aws_iam_role" "feishu_bot" {
  name = "${var.eks_cluster_name}-feishu-bot-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_issuer_host}:sub" = "system:serviceaccount:outline:feishu-bot"
          "${var.oidc_issuer_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { ManagedBy = "terraform" }
}

resource "aws_iam_role_policy" "feishu_bot_devops_agent" {
  name = "devops-agent-chat"
  role = aws_iam_role.feishu_bot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "aidevops:CreateChat",
        "aidevops:SendMessage",
        "aidevops:ListChats",
      ]
      Resource = "arn:aws:aidevops:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:agentspace/${var.devops_agent_space_id}"
    }]
  })
}

# --- IRSA: wecom-bot EKS Pod → aidevops Chat API ---
# Bot 以长连接模式运行在 EKS 上，通过 IRSA 获取调用 DevOps Agent 的权限。
# 与 feishu-bot 平行，直接授予 aidevops:CreateChat/SendMessage/ListChats 到 agentspace ARN。

resource "aws_iam_role" "wecom_bot" {
  name = "${var.eks_cluster_name}-wecom-bot-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_issuer_host}:sub" = "system:serviceaccount:outline:wecom-bot"
          "${var.oidc_issuer_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { ManagedBy = "terraform" }
}

resource "aws_iam_role_policy" "wecom_bot_devops_agent" {
  name = "devops-agent-chat"
  role = aws_iam_role.wecom_bot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "aidevops:CreateChat",
        "aidevops:SendMessage",
        "aidevops:ListChats",
      ]
      Resource = "arn:aws:aidevops:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:agentspace/${var.devops_agent_space_id}"
    }]
  })
}

# --- IRSA: dingtalk-bot EKS Pod → aidevops Chat API ---
# Bot 以 DingTalk Stream 长连接模式运行在 EKS 中，通过 IRSA 获取调用 DevOps Agent 的权限。
# 与 feishu-bot / wecom-bot 平行。

resource "aws_iam_role" "dingtalk_bot" {
  name = "${var.eks_cluster_name}-dingtalk-bot-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_issuer_host}:sub" = "system:serviceaccount:outline:dingtalk-bot"
          "${var.oidc_issuer_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { ManagedBy = "terraform" }
}

resource "aws_iam_role_policy" "dingtalk_bot_devops_agent" {
  name = "devops-agent-chat"
  role = aws_iam_role.dingtalk_bot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "aidevops:CreateChat",
        "aidevops:SendMessage",
        "aidevops:ListChats",
      ]
      Resource = "arn:aws:aidevops:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:agentspace/${var.devops_agent_space_id}"
    }]
  })
}

# ---------------------------------------------------------------------------
# AWS DevOps Agent — Private Connection (VPC Lattice)
#
# Creates a private connection so DevOps Agent can reach VPC-internal
# resources (Grafana ALB, etc.) without going through the public internet.
# ---------------------------------------------------------------------------

resource "null_resource" "devops_agent_private_connection" {
  count = var.vpc_id != "" ? 1 : 0

  triggers = {
    connection_name = var.private_connection_name
    vpc_id          = var.vpc_id
    subnet_ids      = join(",", var.private_subnet_ids)
    host_address    = var.grafana_alb_dns_name
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -e
      REGION="${data.aws_region.current.name}"
      CONN_NAME="${var.private_connection_name}"

      # Build subnet IDs JSON array
      SUBNET_JSON=$(python3 -c "import json; print(json.dumps('${join(",", var.private_subnet_ids)}'.split(',')))")

      # Check if connection already exists
      STATUS=$(aws devops-agent describe-private-connection \
        --region "$REGION" \
        --name "$CONN_NAME" \
        --query 'status' --output text 2>/dev/null || echo "NOT_FOUND")

      if [ "$STATUS" = "ACTIVE" ]; then
        echo "Private connection $CONN_NAME already active, skipping create"
        exit 0
      fi

      if [ "$STATUS" != "NOT_FOUND" ] && [ "$STATUS" != "CREATE_FAILED" ]; then
        echo "Private connection $CONN_NAME in state $STATUS, skipping create"
        exit 0
      fi

      aws devops-agent create-private-connection \
        --region "$REGION" \
        --name "$CONN_NAME" \
        --mode "{\"serviceManaged\":{\"hostAddress\":\"${var.grafana_alb_dns_name}\",\"vpcId\":\"${var.vpc_id}\",\"subnetIds\":$SUBNET_JSON,\"portRanges\":[\"443\"]}}"

      echo "Private connection $CONN_NAME creation initiated"

      # Wait for ACTIVE (up to 10 minutes)
      for i in $(seq 1 60); do
        STATUS=$(aws devops-agent describe-private-connection \
          --region "$REGION" \
          --name "$CONN_NAME" \
          --query 'status' --output text 2>/dev/null || echo "UNKNOWN")
        echo "  [$i/60] status=$STATUS"
        if [ "$STATUS" = "ACTIVE" ]; then
          echo "Private connection is ACTIVE"
          exit 0
        fi
        if [ "$STATUS" = "CREATE_FAILED" ]; then
          echo "ERROR: Private connection creation failed"
          exit 1
        fi
        sleep 10
      done
      echo "ERROR: Timed out waiting for private connection to become ACTIVE"
      exit 1
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -e
      aws devops-agent delete-private-connection \
        --region us-east-1 \
        --name "${self.triggers.connection_name}" 2>/dev/null || true
      echo "Private connection ${self.triggers.connection_name} deleted"
    EOT
  }
}

# ---------------------------------------------------------------------------
# AWS DevOps Agent — Grafana Capability
#
# Three-step process:
#   0. create-private-connection – VPC Lattice path (above)
#   1. register-service  – registers Grafana at the account level
#   2. associate-service – connects Grafana to the "outline" Agent Space
#
# The Grafana SA token is fetched directly from Secrets Manager inside the
# local-exec shell to avoid any Terraform data-source timing issues.
# ---------------------------------------------------------------------------

# Step 1 – Register Grafana at account level
# The Grafana SA token is read directly from Secrets Manager inside the
# local-exec shell, so there is no Terraform data-source timing issue.
# The resulting serviceId is stored in SSM Parameter Store so that the
# associate step can reference it without Terraform interpolation.
resource "null_resource" "devops_agent_grafana_register" {
  depends_on = [null_resource.devops_agent_private_connection]

  triggers = {
    grafana_url       = var.grafana_url
    grafana_name      = var.grafana_service_name
    agent_space_id    = var.devops_agent_space_id
    secret_arn        = var.grafana_sa_token_secret_arn
    private_conn_name = var.private_connection_name
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -e
      REGION="${data.aws_region.current.name}"

      # Read token directly from Secrets Manager at apply time
      TOKEN=$(aws secretsmanager get-secret-value \
        --secret-id "${var.grafana_sa_token_secret_arn}" \
        --region "$REGION" \
        --query SecretString \
        --output text)

      # Build register-service command with optional private connection
      PRIVATE_CONN_ARG=""
      if [ -n "${var.private_connection_name}" ] && [ "${var.vpc_id}" != "" ]; then
        PRIVATE_CONN_ARG="--private-connection-name ${var.private_connection_name}"
      fi

      RESULT=$(aws devops-agent register-service \
        --region "$REGION" \
        --service mcpservergrafana \
        --name "${var.grafana_service_name}" \
        $PRIVATE_CONN_ARG \
        --service-details "{\"mcpservergrafana\":{\"name\":\"${var.grafana_service_name}\",\"endpoint\":\"${var.grafana_url}\",\"description\":\"Grafana instance for outline production monitoring\",\"authorizationConfig\":{\"bearerToken\":{\"tokenName\":\"devops-agent-token\",\"tokenValue\":\"$TOKEN\",\"authorizationHeader\":\"Authorization\"}}}}" \
        --output json)

      SERVICE_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['serviceId'])")
      echo "Grafana registered successfully, serviceId=$SERVICE_ID"

      # Store serviceId in SSM so the associate step can use it
      aws ssm put-parameter \
        --region "$REGION" \
        --name "/devops-agent/grafana-service-id" \
        --value "$SERVICE_ID" \
        --type String \
        --overwrite
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -e
      REGION="us-east-1"

      # Read serviceId from SSM
      SERVICE_ID=$(aws ssm get-parameter \
        --region "$REGION" \
        --name "/devops-agent/grafana-service-id" \
        --query Parameter.Value \
        --output text 2>/dev/null || echo "")

      if [ -n "$SERVICE_ID" ]; then
        aws devops-agent disassociate-service \
          --region "$REGION" \
          --agent-space-id "${self.triggers.agent_space_id}" \
          --service-id "$SERVICE_ID" 2>/dev/null || true

        aws devops-agent deregister-service \
          --region "$REGION" \
          --service mcpservergrafana \
          --service-id "$SERVICE_ID" 2>/dev/null || true

        aws ssm delete-parameter --region "$REGION" --name "/devops-agent/grafana-service-id" 2>/dev/null || true
      fi
      echo "Grafana deregistered"
    EOT
  }
}

# Step 2 – Associate Grafana with the outline Agent Space
resource "null_resource" "devops_agent_grafana_associate" {
  depends_on = [null_resource.devops_agent_grafana_register]

  triggers = {
    grafana_url    = var.grafana_url
    grafana_name   = var.grafana_service_name
    agent_space_id = var.devops_agent_space_id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -e
      REGION="${data.aws_region.current.name}"

      # Read the serviceId registered in step 1
      SERVICE_ID=$(aws ssm get-parameter \
        --region "$REGION" \
        --name "/devops-agent/grafana-service-id" \
        --query Parameter.Value \
        --output text)

      aws devops-agent associate-service \
        --region "$REGION" \
        --agent-space-id "${var.devops_agent_space_id}" \
        --service-id "$SERVICE_ID" \
        --configuration "{\"mcpservergrafana\":{\"endpoint\":\"${var.grafana_url}\"}}" \
        --output json

      echo "Grafana associated with agent space ${var.devops_agent_space_id}, serviceId=$SERVICE_ID"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -e
      REGION="us-east-1"

      SERVICE_ID=$(aws ssm get-parameter \
        --region "$REGION" \
        --name "/devops-agent/grafana-service-id" \
        --query Parameter.Value \
        --output text 2>/dev/null || echo "")

      if [ -n "$SERVICE_ID" ]; then
        aws devops-agent disassociate-service \
          --region "$REGION" \
          --agent-space-id "${self.triggers.agent_space_id}" \
          --service-id "$SERVICE_ID" 2>/dev/null || true
      fi
      echo "Grafana disassociated"
    EOT
  }
}

# ---------------------------------------------------------------------------
# Lambda: investigation-notifier
# EventBridge (aws.aidevops) → 写 GitHub Issue comment
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "investigation_notifier" {
  function_name    = "investigation-notifier"
  role             = aws_iam_role.notifier.arn
  handler          = "investigation_notifier.handler"
  runtime          = "python3.12"
  filename         = local.investigation_notifier_zip
  source_code_hash = data.archive_file.investigation_notifier.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      GITHUB_TOKEN_SECRET   = aws_secretsmanager_secret.github_token.arn
      GITHUB_TICKETS_REPO   = var.github_tickets_repo
      DEVOPS_AGENT_SPACE_ID = var.devops_agent_space_id
      DEVOPS_AGENT_REGION   = data.aws_region.current.name
    }
  }
}

# EventBridge rule: 所有 aws.aidevops Investigation 事件
resource "aws_cloudwatch_event_rule" "devops_agent_investigation" {
  name        = "devops-agent-investigation-to-github"
  description = "Route DevOps Agent investigation lifecycle events to investigation-notifier Lambda"
  event_pattern = jsonencode({
    source      = ["aws.aidevops"]
    detail-type = [{ prefix = "Investigation" }]
    detail = {
      metadata = {
        agent_space_id = [var.devops_agent_space_id]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "devops_agent_investigation" {
  rule = aws_cloudwatch_event_rule.devops_agent_investigation.name
  arn  = aws_lambda_function.investigation_notifier.arn
}

resource "aws_lambda_permission" "devops_agent_investigation" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.investigation_notifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.devops_agent_investigation.arn
}

# ---------------------------------------------------------------------------
# Note: Previously this module created a GitHub Actions OIDC role
# (github-actions-tickets-role) to call aidevops:CreateBacklogTask.
# That approach has been replaced by the Agent Space Webhook (HMAC),
# so no AWS IAM role is needed in the tickets repo anymore.
# ---------------------------------------------------------------------------
