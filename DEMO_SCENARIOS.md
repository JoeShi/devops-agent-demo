# DevOps Agent Demo — 场景设计、机制与触发方式

> 最后更新：2026-04-30

## 一句话概述

在 EKS 上部署 Outline Wiki 作为真实 workload，通过 CronJob 定时或 Web UI 手动注入 4 种故障（Redis/DNS/OOM/DB），经 Prometheus → Alertmanager → SNS → Lambda → GitHub Issue → GitHub Actions Webhook 自动触发 DevOps Agent 调查，Agent 关联 Grafana 指标、OpenSearch 日志、CloudWatch 和 GitHub 变更定位根因，全程 14 分钟内闭环，demo 人员在 Outline Runbook 页面点击链接即可触发和观察。

---

## 告警 → 自动调查机制

```
故障注入（CronJob / Web API）
  → Outline Pod CrashLoopBackOff
  → Prometheus 检测到异常指标，告警规则触发
  → Alertmanager（IRSA 签名）→ SNS topic
  → Lambda feishu-notifier：
      ├── 飞书群发送告警卡片
      └── 关闭同名旧 Issue → 创建新 GitHub Issue（severity=critical）
  → GitHub Actions 监听 issues.opened
      → HMAC-SHA256 签名 → POST DevOps Agent Webhook
  → DevOps Agent 自动创建调查，关联：
      ├── Grafana → Prometheus（Pod restart rate、内存、CPU）
      ├── Grafana → OpenSearch（应用错误日志）
      ├── CloudWatch（RDS/Redis/EKS 资源指标）
      └── GitHub（代码变更、部署历史）
  → EventBridge（aws.aidevops）→ Lambda investigation_notifier
      → 调查状态回写 GitHub Issue 评论（触发/进行中/完成+根因摘要）
```

### 关键配置

| 配置项 | 值 | 说明 |
|---|---|---|
| Alertmanager `repeat_interval` | 15m | 同名告警 15 分钟后可重复发送 |
| Alertmanager `group_by` | alertname, namespace | 不同 alertname 独立分组，互不阻塞 |
| Lambda Issue 策略 | 关闭旧 Issue → 创建新 Issue | 确保每次都触发 `issues.opened` 事件 |
| Lambda 触发条件 | severity=critical 且 status=firing | warning 级别只发飞书不创建 Issue |

### 告警规则（每个场景有独立的 alertname）

| 告警名 | 触发条件 | 对应场景 |
|---|---|---|
| `OutlinePodCrashLooping` | restart rate > 3/15min，持续 5min | Redis / 通用 |
| `OutlinePodOOMKilled` | 容器被 OOM Kill | OOM Kill |
| `OutlineDNSFailure` | CrashLoop + Error 退出，持续 3min | DNS 故障 |
| `OutlineDBConnectionFailure` | CrashLoopBackOff 且非 OOM，持续 5min | DB 连接失败 |

独立的 alertname 确保 4 个场景的告警互不影响，不受 `repeat_interval` 限制。

---

## 四大场景

### 场景 1：Redis 级联故障

| 项目 | 内容 |
|---|---|
| 注入方式 | NetworkPolicy 阻断 6379 + Patch `REDIS_URL=redis://10.255.255.1:6379` |
| 为什么两层 | Outline 对 Redis 断连有容错（health check 不查 Redis），单靠 NetworkPolicy 不会 crash |
| Pod 日志 | `Redis error: connect ETIMEDOUT` |
| Agent 调查重点 | CloudWatch 显示 Redis 健康 vs 应用连不上 → 发现 REDIS_URL 被篡改 |
| 自动恢复 | `rollout undo` + 删除 NetworkPolicy |
| 实测结果 | Issue #13 ✅ Agent 完美定位，含完整因果链，识别出 chaos 注入 |

### 场景 2：DNS 解析故障

| 项目 | 内容 |
|---|---|
| 注入方式 | Patch `dnsPolicy: None` + `dnsConfig.nameservers: [10.255.255.1]` |
| Pod 日志 | `getaddrinfo EAI_AGAIN outline-demo-pg.cluster-...rds.amazonaws.com` |
| Agent 调查重点 | 最有迷惑性 — RDS/Redis 都健康但全部连不上，需要排查 DNS 层 |
| 自动恢复 | `rollout undo` |
| 实测结果 | Issue #15 Agent 调查已启动 |

### 场景 3：OOM Kill

| 项目 | 内容 |
|---|---|
| 注入方式 | Patch 内存限制从 `1Gi` 降到 `200Mi`（Outline 需要 300-500Mi） |
| Pod 状态 | `OOMKilled`，exit code 137 |
| Agent 调查重点 | 识别 OOM Kill（exit 137）vs 其他 CrashLoop，内存启动即满 = 资源配置问题 |
| 自动恢复 | `rollout undo` |
| 实测结果 | Issue #16 ✅ Agent 2 分钟完成调查，最快的场景 |

### 场景 4：DB 连接失败

| 项目 | 内容 |
|---|---|
| 注入方式 | Patch `DATABASE_URL=postgres://outline:fake@10.255.255.1:5432/outline` |
| Pod 日志 | 数据库连接超时 |
| Agent 调查重点 | CloudWatch RDS 完全健康 vs 应用连不上 → 检查 Deployment 变更发现 URL 被覆盖 |
| 自动恢复 | `rollout undo` |
| 实测结果 | Issue #19 Agent 调查已启动 |

---

## 触发方式

### 方式 1：CronJob 定时触发（每周日自动执行）

| CronJob | Schedule (UTC) | 北京时间 |
|---|---|---|
| `chaos-redis-failure` | `0 2 * * 0` | 周日 10:00 |
| `chaos-dns-failure` | `0 4 * * 0` | 周日 12:00 |
| `chaos-oom-kill` | `0 6 * * 0` | 周日 14:00 |
| `chaos-db-exhaust` | `0 8 * * 0` | 周日 16:00 |

每个间隔 2 小时，不会重叠。每个场景持续约 10-12 分钟后自动恢复。

**原理**：K8s CronJob 按 schedule 自动创建 Job → Job Pod 使用 `chaos-runner` ServiceAccount 执行 `kubectl patch`/`kubectl apply` 注入故障 → `sleep` 等待告警链路走完 → `kubectl rollout undo` 自动恢复。

### 方式 2：Web UI 手动触发（Demo 人员使用）

chaos-trigger API 部署在 EKS 中，通过 ALB Ingress 暴露到公网：

**Base URL**：`https://alb-outline.devops-agent.xyz/chaos`

| 操作 | URL | 说明 |
|---|---|---|
| 触发 Redis 故障 | [/chaos/trigger/redis-failure](https://alb-outline.devops-agent.xyz/chaos/trigger/redis-failure) | 点击即触发 |
| 触发 DNS 故障 | [/chaos/trigger/dns-failure](https://alb-outline.devops-agent.xyz/chaos/trigger/dns-failure) | 点击即触发 |
| 触发 OOM Kill | [/chaos/trigger/oom-kill](https://alb-outline.devops-agent.xyz/chaos/trigger/oom-kill) | ⭐ 推荐首选 |
| 触发 DB 故障 | [/chaos/trigger/db-exhaust](https://alb-outline.devops-agent.xyz/chaos/trigger/db-exhaust) | 点击即触发 |
| 查看状态 | [/chaos/status](https://alb-outline.devops-agent.xyz/chaos/status) | Pod 状态 + 活跃 Job |
| 紧急清理 | [/chaos/cleanup](https://alb-outline.devops-agent.xyz/chaos/cleanup) | 立即恢复环境 |

**原理**：Flask API Pod 使用 `chaos-runner` ServiceAccount，收到 HTTP 请求后执行 `kubectl create job --from=cronjob/<name>` 创建一次性 Job，等同于手动触发 CronJob。Demo 人员无需终端、kubectl 或 AWS 凭证，在浏览器中点击链接即可操作。

**架构**：
```
浏览器点击链接
  → ALB (alb-outline.devops-agent.xyz/chaos/*)
  → chaos-trigger Pod (Flask, port 8080)
  → kubectl create job --from=cronjob/chaos-xxx
  → Job Pod 执行故障注入
  → 后续链路同 CronJob 自动触发
```

### RBAC 配置

`chaos-runner` ServiceAccount 拥有以下权限（`outline` namespace）：

| 资源 | 权限 |
|---|---|
| `networkpolicies` | create, delete, get, list |
| `pods` | delete, get, list |
| `deployments`, `replicasets` | get, list, patch, update |
| `cronjobs`, `jobs` | get, list, create, delete |

---

## 文件清单

| 文件 | 用途 |
|---|---|
| `k8s/chaos-cronjob.yaml` | Redis 场景 CronJob + ServiceAccount + RBAC |
| `k8s/chaos-dns-failure.yaml` | DNS 场景 CronJob |
| `k8s/chaos-oom-kill.yaml` | OOM Kill 场景 CronJob |
| `k8s/chaos-db-exhaust.yaml` | DB 连接失败场景 CronJob |
| `k8s/chaos-trigger/deployment.yaml` | Web API（ConfigMap + Deployment + Service） |
| `k8s/chaos-trigger/app.py` | API 源码（备份，实际通过 ConfigMap 部署） |
| `grafana/alerts.yaml` | PrometheusRule（含 4 条场景专用告警） |
| `terraform/modules/observability/main.tf` | Alertmanager 配置（subject + repeat_interval） |
| `terraform/modules/integration/lambda/feishu_notifier.py` | Lambda（纯文本解析 + 关闭旧 Issue 创建新 Issue） |
| `docs/demo-runbook.md` | Outline Runbook 页面内容（粘贴到 Outline Wiki） |
