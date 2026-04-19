# AWS DevOps Agent 演示 — 基于 EKS 部署 Outline

在 EKS 上部署 Outline Wiki，集成完整的可观测性方案（Prometheus + Grafana + OpenSearch）以及 AWS DevOps Agent。包含飞书通知和故障注入脚本，用于现场演示场景。

## 架构

```
                          ┌─────────────────────────────────────────────┐
                          │              Amazon Cognito                 │
                          │         (User Pool + OAuth 2.0)             │
                          └──────────┬──────────────┬──────────────────┘
                                     │              │
Internet ─→ Route53 ─→ CloudFront ─→ ALB ─→ EKS    │
  (outline.devops-agent.xyz)              │  ├── Outline Web x3 ←──────┘ (OIDC login)
                                          │  ├── Outline Worker
                                          │  ├── Prometheus + Grafana ←─┘ (OAuth login)
                                          │  ├── Fluent Bit → OpenSearch
                                          │  └── Feishu Bot Pod (WebSocket + IRSA)
                                          │
Internet ─→ Route53 ─→ ALB (HTTPS) ──────┘
  (grafana.devops-agent.xyz)

EKS ←→ Aurora PostgreSQL (Multi-AZ)
EKS ←→ ElastiCache Redis (Multi-AZ, TLS)

── Alert → Ticket → Investigation Flow ─────────────────────────────────────
Prometheus → Alertmanager → SNS → Lambda (feishu_notifier)
  ├── 飞书告警卡片
  └── GitHub Issue (devops-agent-demo-tickets, severity=critical/high)
        └── issues.opened → GitHub Actions → HMAC Webhook
              → DevOps Agent creates investigation

EventBridge (aws.aidevops) → Lambda (investigation_notifier)
  ├── Investigation Created    → issue comment: "调查已创建"
  ├── Investigation In Progress → issue comment: "调查开始 + operator web URL"
  ├── Investigation Completed  → issue comment: "根因摘要"
  └── other state changes      → issue comment: 状态更新

── AWS DevOps Agent Space (outline) ────────────────────────────────────────
  ├── CloudWatch  (AWS resource metrics, auto-detected)
  ├── Grafana     (Prometheus metrics + OpenSearch logs, Terraform-managed)
  ├── GitHub      (devops-agent-demo + outline repos, OAuth)
  └── Notifications: EventBridge → Lambda → Feishu Webhook
                     EventBridge → Lambda → GitHub Issue comments
```

**代码仓库：**

| 仓库 | 用途 |
|------|------|
| [JoeShi/outline](https://github.com/JoeShi/outline) | Outline 应用源代码 |
| [JoeShi/devops-agent-demo](https://github.com/JoeShi/devops-agent-demo) | 基础设施代码（Terraform、K8s 清单、Grafana 配置） |
| [JoeShi/devops-agent-demo-tickets](https://github.com/JoeShi/devops-agent-demo-tickets) | 事件工单（由 Lambda 根据告警自动创建） |

**关键流程：**
- **Outline**：用户 → Route53 → CloudFront → ALB → EKS Pod，通过 Cognito OIDC 认证
- **Grafana**：用户 → Route53 → ALB（直连，无 CDN）→ Grafana Pod，通过 Cognito OAuth 认证
- **告警通知**：Prometheus → Alertmanager → SNS → Lambda → 飞书卡片 + GitHub Issue（无公网端点）
- **SRE 对话**：用户在飞书 @Bot → EKS Pod（WebSocket）→ DevOps Agent Chat API → 飞书回复
- **密钥管理**：AWS Secrets Manager → External Secrets Operator → K8s Secrets（仓库中无明文）

## 目录结构

```
.
├── terraform/                    # Infrastructure as Code
│   ├── main.tf                   # Root module
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── vpc/                  # VPC, 3 AZs, public/private/data subnets
│       ├── eks/                  # EKS cluster, managed node group, OIDC
│       ├── data-stores/          # RDS PostgreSQL, ElastiCache Redis, OpenSearch
│       ├── auth/                 # Cognito User Pool, App Clients (Outline + Grafana)
│       ├── cdn/                  # CloudFront, ACM certificates, Route53 records
│       ├── observability/        # kube-prometheus-stack, Fluent Bit, Alertmanager IRSA (Helm)
│       └── integration/          # SNS, EventBridge, Lambda, IRSA for Feishu Bot
│           └── lambda/           # feishu_notifier.py, investigation_notifier.py
├── k8s/                          # Kubernetes manifests (Kustomize)
│   ├── namespace.yaml
│   ├── secrets.yaml
│   ├── deployment.yaml           # Outline web (3 replicas)
│   ├── worker-deployment.yaml    # Outline worker
│   ├── feishu-bot-deployment.yaml # Feishu Bot (WebSocket + IRSA)
│   ├── feishu-bot/               # Bot source code + Dockerfile
│   │   ├── app.py
│   │   ├── Dockerfile
│   │   └── requirements.txt
│   ├── service.yaml
│   ├── ingress.yaml              # ALB Ingress
│   ├── hpa.yaml                  # Auto-scaling
│   ├── servicemonitor.yaml       # Prometheus scrape config
│   └── kustomization.yaml
├── github-actions/
│   └── deploy.yml                # CD workflow (build → ECR → EKS → notify)
├── grafana/
│   ├── alerts.yaml               # PrometheusRule (7 alert rules)
│   ├── dashboards/
│   │   └── outline-app-overview.json  # Main dashboard (Terraform-managed)
│   └── contact-points.yaml       # Alertmanager SNS receiver 参考配置
├── scripts/
│   └── chaos.sh                  # Fault injection for demo scenarios
└── README.md                     # This file
```

## 前置条件

- 已配置好凭证的 AWS CLI v2
- Terraform >= 1.5.0
- kubectl
- Helm 3
- 已启用 Actions 的 GitHub 仓库
- 飞书机器人（需要 webhook URL 用于通知，以及应用凭证用于双向对话）
- Docker（用于构建飞书 Bot 镜像）

## 第一步：部署基础设施

```bash
cd terraform

# Configure variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# Create S3 backend (first time only)
aws s3 mb s3://outline-terraform-state-<ACCOUNT_ID> --region us-east-1
aws dynamodb create-table \
  --table-name outline-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1

# Deploy
terraform init
terraform plan
terraform apply
```

以上命令将创建：VPC（3 个可用区）→ EKS 集群 → RDS + Redis + OpenSearch → Cognito User Pool → CloudFront + ACM + Route53 → Prometheus + Grafana + Fluent Bit → SNS + EventBridge + Lambda。

## 第二步：部署 Outline 应用

```bash
# Configure kubectl
aws eks update-kubeconfig --name outline-demo --region us-east-1

# Update secrets (edit k8s/secrets.yaml with real values from terraform output)
terraform output -json  # Get RDS/Redis endpoints

# Deploy
kubectl apply -k k8s/

# Apply Grafana alerts and dashboard
kubectl apply -f grafana/alerts.yaml
```

通过 Grafana UI 导入 `grafana/dashboards/outline-app-overview.json`（Dashboards → Import），或让 Terraform 通过 `grafana-dashboard-outline` ConfigMap 自动配置。

## 第三步：配置 AWS DevOps Agent

Grafana 能力完全由 Terraform 管理。其他能力（GitHub、Slack 等）仍需在控制台手动设置。

### 3a. 前置条件

在执行 apply 之前，确保 `terraform.tfvars` 中已设置以下变量：

```hcl
devops_agent_space_id = "<your-agent-space-id>"   # from AWS console
grafana_admin_password = "<grafana-admin-password>"
```

查找 Agent Space ID：

```bash
aws devops-agent list-agent-spaces --region us-east-1
```

### 3b. Grafana 能力与私有连接（Terraform 管理）

运行 `terraform apply` 会自动完成完整的 Grafana 集成，包括创建 VPC Lattice 私有连接，使 DevOps Agent 通过 AWS 内部网络而非公网访问 Grafana。

**Terraform 执行的操作：**

1. **创建私有连接**（`outline-vpc-private`），使用 `aws devops-agent create-private-connection`：
   - 在私有子网（`us-east-1a`、`us-east-1b`）中创建 VPC Lattice 资源网关
   - 主机地址：Grafana ALB 内部 DNS
   - 端口：443
   - 流量完全在 AWS 网络内部传输

2. **创建 Grafana Service Account**（`devops-agent`，Viewer 角色），通过 Helm release 部署后调用 Grafana HTTP API 创建，并将生成的 token 存储到 AWS Secrets Manager（`grafana-devops-agent-token`）。

3. **在账户级别注册 Grafana**，使用 `aws devops-agent register-service --private-connection-name outline-vpc-private`：
   - 服务名称：`outline-grafana`
   - 端点：`https://grafana.devops-agent.xyz`
   - 认证：Bearer token（第 2 步中的 Service Account token）
   - 私有连接：`outline-vpc-private`（VPC Lattice 路径）

4. **将 Grafana 关联到 `outline` Agent Space**，使用 `aws devops-agent associate-service`，使 Agent 能够在事件调查期间通过 Grafana 查询 Prometheus 指标和 OpenSearch 日志。

> **注意：** 公网 Grafana URL（`https://grafana.devops-agent.xyz`）仍可供人工用户访问。私有连接仅影响 DevOps Agent 访问 Grafana 的方式——所有 Agent 流量通过私有子网中的 VPC Lattice ENI 传输。

Service ID 持久化存储在 SSM Parameter Store（`/devops-agent/grafana-service-id`）中，以便 `terraform destroy` 能够干净地注销集成。

**执行命令：**

```bash
cd terraform
terraform apply \
  -target=module.integration.null_resource.devops_agent_private_connection \
  -target=module.observability.aws_secretsmanager_secret.grafana_sa_token \
  -target=module.observability.null_resource.grafana_sa_token \
  -target=module.integration.null_resource.devops_agent_grafana_register \
  -target=module.integration.null_resource.devops_agent_grafana_associate
```

> **注意：** 私有连接创建需要约 3-5 分钟（VPC Lattice 资源网关配置）。Terraform 会轮询直到状态变为 `ACTIVE`，然后再继续注册 Grafana。

**验证：**

```bash
# Check the service was registered
aws devops-agent list-services --region us-east-1

# Check the association on the agent space
aws devops-agent get-association \
  --agent-space-id <agent-space-id> \
  --association-id <association-id> \
  --region us-east-1
```

关联完成后，DevOps Agent 即可通过 Grafana 查询 Prometheus 指标和 OpenSearch 日志进行事件调查。

> **注意**：告警通知链路走 Alertmanager → SNS → Lambda → GitHub Issue → Webhook 触发调查，不需要在 Grafana 中配置额外的 Contact Point。

### 3c. 其他能力（手动配置）

| 能力 | 配置方式 |
|------|----------|
| **CloudWatch** | 自动检测——无需配置 |
| **GitHub** | 控制台 → Agent Space → Capabilities → Add GitHub → 通过 OAuth 认证，然后使用 CLI 关联仓库（见下文） |
| **Slack / 飞书** | EventBridge → Lambda 已由 Terraform 配置；如需 Slack 双向通信，通过控制台添加 |

#### GitHub 仓库关联（CLI）

在控制台完成 OAuth 认证后，使用 CLI 关联仓库：

```bash
# Associate devops-agent-demo repo
aws devops-agent associate-service \
  --region us-east-1 \
  --agent-space-id <agent-space-id> \
  --service-id <github-service-id> \
  --configuration '{
    "github": {
      "repoName": "devops-agent-demo",
      "repoId": "1213706482",
      "owner": "JoeShi",
      "ownerType": "user",
      "instanceIdentifier": "github.com"
    }
  }'

# Associate outline repo
aws devops-agent associate-service \
  --region us-east-1 \
  --agent-space-id <agent-space-id> \
  --service-id <github-service-id> \
  --configuration '{
    "github": {
      "repoName": "outline",
      "repoId": "1212508509",
      "owner": "JoeShi",
      "ownerType": "user",
      "instanceIdentifier": "github.com"
    }
  }'
```

### 3e. GitHub Issues → DevOps Agent 自动调查

当在 [devops-agent-demo-tickets](https://github.com/JoeShi/devops-agent-demo-tickets) 中创建 GitHub Issue 时，系统会自动：

1. 触发与该 Issue 关联的 DevOps Agent 调查
2. 调查开始后在 Issue 上发表评论，附带 operator web URL
3. 每次调查状态变更时在 Issue 上发表状态更新评论
4. 调查完成后发表根因摘要评论

#### 工作原理

```
GitHub Issue created (issues.opened)
  → GitHub Actions workflow (.github/workflows/trigger-investigation.yml)
    → 构建 incident payload (incidentId = "<repo>#<number>")
    → HMAC-SHA256 签名
    → POST to Agent Space Webhook URL
      → DevOps Agent creates investigation
    → 在 Issue 上发表评论："调查已触发"

EventBridge (aws.aidevops) → Lambda (investigation_notifier)
  → 调用 get-backlog-task 获取 reference.referenceId
  → 解析 referenceId ("<repo>#<number>") 定位 GitHub Issue
  → Investigation Created    → GitHub issue comment: "调查已创建"
  → Investigation In Progress → GitHub issue comment: "调查进行中 + operator web URL"
  → Investigation Completed  → GitHub issue comment: "根因摘要"
  → Investigation Failed/Cancelled → GitHub issue comment: 对应状态
```

#### 组件（已通过 Terraform 部署）

| 组件 | 位置 | 用途 |
|------|------|------|
| GitHub Actions 工作流 | `devops-agent-demo-tickets/.github/workflows/trigger-investigation.yml` | 监听 `issues.opened` 事件，通过 HMAC Webhook 触发 DevOps Agent 调查 |
| Lambda `investigation_notifier` | `terraform/modules/integration/lambda/investigation_notifier.py` | 接收 EventBridge 事件，通过 `get-backlog-task` 解析 Issue 映射，将评论写回 GitHub Issue |
| EventBridge 规则 | `terraform/modules/integration/main.tf` | 将 `aws.aidevops` Investigation 事件（按 Agent Space ID 过滤）路由到 Lambda |

#### 配置步骤

**步骤 1：部署基础设施**（如果已运行 `terraform apply` 则跳过）

```bash
cd terraform
terraform apply
```

**步骤 2：获取 Agent Space Webhook 凭证**

在 AWS 控制台的 Agent Space 页面，或通过 `associate-service` 输出获取：
- **Webhook URL**：Agent Space 的 incident webhook endpoint
- **Webhook Secret**：用于 HMAC-SHA256 签名的密钥

**步骤 3：设置 GitHub Actions Secrets**

在 [devops-agent-demo-tickets](https://github.com/JoeShi/devops-agent-demo-tickets) 仓库中，进入 **Settings → Secrets and variables → Actions → New repository secret**，添加：

| Secret | 值 |
|--------|-----|
| `DEVOPS_AGENT_WEBHOOK_URL` | Agent Space Webhook URL |
| `DEVOPS_AGENT_WEBHOOK_SECRET` | Webhook HMAC 签名密钥 |

> **注意**：不需要 AWS IAM 角色或 OIDC 配置——Webhook 方案通过 HMAC 签名认证，无需 AWS 凭证。

**步骤 4：推送工作流文件**

```bash
cd ../devops-agent-demo-tickets
git add .github/workflows/trigger-investigation.yml
git commit -m "Add GitHub Actions workflow to trigger DevOps Agent investigation on new issues"
git push origin main
```

**步骤 5：验证**

在 tickets 仓库中创建一个测试 Issue：

```bash
gh issue create \
  --repo JoeShi/devops-agent-demo-tickets \
  --title "[TEST] Verify DevOps Agent auto-investigation" \
  --body "This is a test issue to verify the end-to-end investigation flow." \
  --label "high"
```

预期结果：
1. GitHub Actions 工作流运行 → Webhook 触发 DevOps Agent 调查
2. Issue 上出现评论："DevOps Agent 调查已触发"，附带 incident ID
3. EventBridge 投递 `Investigation In Progress` → Lambda 发表评论："调查进行中" + 可点击的 operator web URL
4. EventBridge 投递 `Investigation Completed` → Lambda 发表评论：根因摘要

#### Operator web 调查 URL 格式

```
https://<space-id>.aidevops.global.app.aws/<space-id>/investigation/<task_id>
```

此 URL 包含在"调查进行中"评论中，工程师可以直接点击跳转到调查详情页面。

### 3d. 飞书 Bot — SRE 对话（双向通信）

飞书 Bot 以长连接 WebSocket Pod 形式运行在 EKS 中，通过 IRSA 将消息转发到 DevOps Agent Chat API。无需 API Gateway 或公网回调 URL。

#### 3d-1. 创建飞书应用

1. 前往[飞书开放平台](https://open.feishu.cn/app) → 创建企业自建应用
2. **添加能力**：应用能力 → 机器人
3. **启用 WebSocket 模式**：事件与回调 → 选择"使用长连接接收事件"
4. **订阅事件**：事件与回调 → 添加事件 → `im.message.receive_v1`（接收消息）
5. **开通权限**（权限管理 → 开通）：

   | 权限 | Scope | 用途 |
   |------|-------|------|
   | 获取群组中其他机器人和用户@当前机器人的消息 | — | **事件投递必需。** 缺少此权限时，Bot 可通过 WebSocket 连接但不会收到任何消息事件。 |
   | im:message | `im:message` | 读取聊天中的消息 |
   | im:message:send_as_bot | `im:message:send_as_bot` | 以机器人身份发送回复 |
   | 获取群组信息 | `im:chat:readonly` | 读取群聊元数据 |

   > ⚠️ **关键提示**：第一个权限与 `im:message` 是独立的。即使已开通 `im:message`，如果未授予此事件级权限，Bot 将静默地收不到任何消息。请检查事件页面的"所需权限"列——必须显示"已开通"。

6. **发布应用**：版本管理 → 创建版本 → 提交审核
   - 对于测试租户（"测试应用"），更改会立即生效，无需审核。
7. **将机器人添加到群组**：打开目标飞书群 → 设置 → 机器人 → 添加该机器人

在凭证与基本信息页面记录 **App ID** 和 **App Secret**。

#### 3d-2. 创建 Secrets Manager 密钥

```bash
aws secretsmanager create-secret \
  --name outline/feishu-bot \
  --region us-east-1 \
  --secret-string '{
    "FEISHU_APP_ID": "<your-app-id>",
    "FEISHU_APP_SECRET": "<your-app-secret>",
    "DEVOPS_AGENT_SPACE_ID": "<your-agent-space-id>"
  }'
```

`k8s/feishu-bot-deployment.yaml` 中的 ExternalSecret 会自动将其同步为 K8s Secret。

#### 3d-3. 构建并推送 Bot 镜像

```bash
cd k8s/feishu-bot

# Create ECR repo (first time only)
aws ecr create-repository --repository-name feishu-bot --region us-east-1

# Build and push (must be linux/amd64 for EKS)
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com

docker build --platform linux/amd64 \
  -t <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/feishu-bot:latest .
docker push <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/feishu-bot:latest
```

#### 3d-4. 部署

```bash
kubectl apply -f k8s/feishu-bot-deployment.yaml
```

验证：

```bash
# Pod should be Running
kubectl get pods -n outline -l app=feishu-bot

# Logs should show WebSocket connected
kubectl logs -n outline -l app=feishu-bot
# Expected: "connected to wss://msg-frontier.feishu.cn/ws/v2?..."
```

#### 3d-5. 故障排查

| 症状 | 原因 | 修复方法 |
|------|------|----------|
| `CreateContainerConfigError` | Dockerfile 使用了非数字 `USER` 但配置了 `runAsNonRoot` | 在 Dockerfile 中使用 `USER 1000`（数字 UID） |
| WebSocket 已连接但收不到消息 | 事件权限未授予 | 在权限管理中开通"获取群组中其他机器人和用户@当前机器人的消息"，然后重启 Pod |
| `AttributeError: 'EventDispatcherHandlerBuilder' object has no attribute 'register'` | lark-oapi >= 1.4 更改了 API | 使用 `register_p2_im_message_receive_v1()` 替代 `.register()` |
| `Could not connect to endpoint aidevops.us-east-1.amazonaws.com` | DevOps Agent API 仅在 VPC 内可解析 | Bot 必须在 EKS 内运行（不能在本地）；确保 Agent Space 已创建 |

## 第四步：配置 CI/CD

将工作流文件复制到你的仓库：

```bash
cp github-actions/deploy.yml .github/workflows/deploy.yml
```

设置 GitHub Actions secrets：
- `AWS_DEPLOY_ROLE_ARN` — 用于 OIDC 联合认证的 IAM 角色 ARN
- `FEISHU_WEBHOOK_URL` — 飞书 incoming webhook URL

## 第五步：运行演示场景

详细的演示方案（包含 5 个场景的故事线、注入方式、调查过程、演示亮点和环境 checklist）请参考 [DEMO_PLAN.md](./DEMO_PLAN.md)。

快速故障注入命令：

```bash
./scripts/chaos.sh db-exhaust       # 场景 1：DB 连接池耗尽
./scripts/chaos.sh slow-deploy      # 场景 2：坏部署延迟飙升
./scripts/chaos.sh redis-failure    # 场景 3：Redis 级联故障

# 清理
./scripts/chaos.sh db-exhaust --cleanup
./scripts/chaos.sh slow-deploy --cleanup
./scripts/chaos.sh redis-failure --cleanup
```

## 关键设计决策

**Grafana 作为统一遥测网关**：DevOps Agent 内置的 Grafana MCP 服务器可连接 Grafana 中配置的所有数据源。一次集成即可覆盖 Prometheus（指标）和 OpenSearch（日志）。

**通过 Resource Explorer 发现 Terraform 资源**：由于 Terraform 不使用 CloudFormation，所有资源均通过一致的标签（`App=outline`、`Environment=production`、`ManagedBy=terraform`）进行标记，并通过 AWS Resource Explorer 发现。

**GitHub Issues 作为工单系统**：事件会在 [devops-agent-demo-tickets](https://github.com/JoeShi/devops-agent-demo-tickets) 中创建 GitHub Issue。GitHub Actions 工作流调用 `aws devops-agent create-backlog-task` 并通过 `--reference` 指向该 Issue，将调查与工单关联。EventBridge（`aws.aidevops`）将所有调查状态变更路由到 Lambda，Lambda 将评论写回 Issue——包括 operator web URL 和最终根因摘要。

**飞书双重集成**：EventBridge → Lambda 用于单向告警通知；EKS Pod（WebSocket + IRSA）用于通过 DevOps Agent Chat API 进行双向 SRE 对话。无公网端点——Lambda 仅由 EventBridge 调用。

## 预估成本

| 资源 | 规格 | 月估算费用 |
|------|------|-----------|
| EKS Cluster | 控制平面 | $73 |
| EC2 (3x m5.xlarge) | 节点组 | $432 |
| RDS PostgreSQL | db.r6g.large Multi-AZ | $380 |
| ElastiCache Redis | cache.r6g.large Multi-AZ | $290 |
| OpenSearch | 2x t3.medium.search | $146 |
| NAT Gateway | 2 个可用区 | $65 |
| CloudFront | Outline CDN | $5 |
| ALB | 2 个实例（Outline + Grafana） | $44 |
| Cognito | User Pool（免费套餐） | $0 |
| Lambda | 极少量使用 | <$1 |
| **合计** | | **约 $1,436** |

非生产演示环境可使用 `t3.medium` 实例和单可用区部署，费用可降至约 $500/月。

## 清理

```bash
# Delete K8s resources first
kubectl delete -k k8s/

# Destroy infrastructure
cd terraform
terraform destroy
```