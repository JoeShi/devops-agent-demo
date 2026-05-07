# DevOps Agent 自动调查闭环 — 环境配置与故障注入总结

> 最后更新：2026-04-30

## 环境配置

### 基础设施（AWS us-east-1, Account 604179600882）

一个部署在 EKS 上的 Outline Wiki 应用，作为 DevOps Agent 的演示 workload：

| 层 | 组件 | 规格 |
|---|---|---|
| 入口 | Route53 → CloudFront → ALB | `outline.devops-agent.xyz` |
| 计算 | EKS v1.35, 3× m5.xlarge | Outline Web ×3 + Worker ×1 + Feishu Bot |
| 数据 | Aurora PostgreSQL 16.6 Multi-AZ | db.r6g.large, 读写分离 |
| 缓存 | ElastiCache Redis Multi-AZ TLS | cache.r6g.large, 2 节点 |
| 日志 | OpenSearch 2.11 | 2× t3.medium.search, VPC 内 |
| 监控 | Prometheus + Grafana + Alertmanager | kube-prometheus-stack Helm |
| 认证 | Cognito + Amazon Federate | Midway SSO 登录 |

### 告警 → 自动调查机制

整个系统的核心链路，由 6 个组件串联：

```
Prometheus  →  Alertmanager  →  SNS  →  Lambda  →  GitHub Issue  →  GitHub Actions  →  DevOps Agent
 (检测)         (路由)          (桥接)   (通知+工单)   (工单仓库)       (Webhook触发)      (自动调查)
```

- **Prometheus**：10 条告警规则监控 Outline 应用（CrashLoop/OOM/高延迟/队列积压等）和 AWS 基础设施（RDS 连接数/CPU、Redis 内存）。
- **Alertmanager**：通过 IRSA 签名将告警发送到 SNS topic `grafana-alerts-to-notifier`。配置了 `subject: "Outline Alert"` 避免 SNS 100 字符限制。`repeat_interval: 4h`。
- **Lambda `feishu-notifier`**：收到 SNS 消息后：
  - 解析纯文本或 JSON 格式的告警消息（Alertmanager SNS 发纯文本）
  - 向飞书群发送告警卡片（所有告警）
  - severity=critical 且 status=firing 时：关闭同名旧 Issue → 创建新 Issue（确保触发 `issues.opened`）
  - 工单仓库：`JoeShi/devops-agent-demo-tickets`
- **GitHub Actions**：`devops-agent-demo-tickets` 仓库的 workflow 监听 `issues.opened`，用 HMAC-SHA256 签名向 DevOps Agent Space Webhook 发送 incident payload。
- **DevOps Agent**：收到 Webhook 后自动创建调查，关联 4 个数据源：
  - Grafana → Prometheus 指标（Pod restart rate、内存、CPU）
  - Grafana → OpenSearch 日志（应用错误日志）
  - CloudWatch（RDS/Redis/EKS 资源指标）
  - GitHub（代码变更、部署历史）
- **EventBridge**：监听 `aws.aidevops` 事件，通过 Lambda `investigation_notifier` 将调查状态回写到 GitHub Issue 评论（创建/进行中/完成+根因摘要）。

### DevOps Agent 接入方式

| 能力 | 连接方式 |
|---|---|
| CloudWatch | 自动检测 |
| Grafana | VPC Lattice 私有连接（流量不走公网） |
| GitHub | OAuth + 仓库关联 |

---

## 全部 Chaos 场景

4 个 CronJob 部署在 `outline` namespace，schedule 错开不会冲突。每个场景约 10-12 分钟，自动注入 + 自动恢复。

### 场景 1：Redis 级联故障

| 项目 | 内容 |
|---|---|
| **CronJob** | `chaos-redis-failure` |
| **文件** | `k8s/chaos-cronjob.yaml` |
| **Schedule** | `0 */4 * * *`（每 4 小时） |
| **注入方式** | NetworkPolicy 阻断 Redis 6379 + Patch Deployment 注入 `REDIS_URL=redis://10.255.255.1:6379` |
| **故障表现** | Pod 日志 `Redis error: connect ETIMEDOUT` → CrashLoopBackOff |
| **触发告警** | `OutlinePodCrashLooping` (critical) |
| **Agent 调查重点** | CloudWatch 显示 ElastiCache Redis 完全健康，但应用连不上 → 需要排查网络层（NetworkPolicy）和配置变更（REDIS_URL 被覆盖） |
| **自动恢复** | `kubectl rollout undo` + 删除 NetworkPolicy |
| **验证 Issue** | #13 ✅ 调查完成 |

**为什么需要两层注入**：Outline 对 Redis 断连有容错 — health check 不检查 Redis，断连后降级运行不 crash。单靠 NetworkPolicy 无法让 Pod 进入 CrashLoop。注入无效 REDIS_URL 后，新 Pod 启动时连接超时 → 进程退出 → 反复 crash。

### 场景 2：DNS 解析故障

| 项目 | 内容 |
|---|---|
| **CronJob** | `chaos-dns-failure` |
| **文件** | `k8s/chaos-dns-failure.yaml` |
| **Schedule** | `30 1,9,17 * * *`（每 8 小时） |
| **注入方式** | Patch Deployment 设置 `dnsPolicy: None` + `dnsConfig.nameservers: [10.255.255.1]`（不可达 DNS） |
| **故障表现** | Pod 日志 `getaddrinfo EAI_AGAIN outline-demo-pg.cluster-...rds.amazonaws.com` → `Failed to connect to database` → CrashLoopBackOff |
| **触发告警** | `OutlinePodCrashLooping` (critical) |
| **Agent 调查重点** | 最有迷惑性的场景 — RDS 和 Redis 在 CloudWatch 中都完全健康，但应用日志显示所有域名都解析失败。Agent 需要深入到网络/DNS 层，而不是归因于数据库故障 |
| **自动恢复** | `kubectl rollout undo` |
| **验证 Issue** | #15 ✅ 调查启动 |

### 场景 3：OOM Kill（内存不足）

| 项目 | 内容 |
|---|---|
| **CronJob** | `chaos-oom-kill` |
| **文件** | `k8s/chaos-oom-kill.yaml` |
| **Schedule** | `0 3,11,19 * * *`（每 8 小时） |
| **注入方式** | Patch Deployment 将内存限制从 `1Gi` 降到 `200Mi`（Outline 启动需要 ~300-500Mi） |
| **故障表现** | 容器启动后内存超限 → OOM Kill (exit code 137) → CrashLoopBackOff |
| **触发告警** | `OutlinePodCrashLooping` (critical) |
| **Agent 调查重点** | 需要识别 OOM Kill 模式（exit code 137）与其他 CrashLoop 的区别。内存曲线是启动即满（不是渐进泄漏），说明是资源配置问题而非代码 bug |
| **自动恢复** | `kubectl rollout undo`（注意：有时需要手动 patch 回 `memory: 1Gi`） |
| **验证 Issue** | #16 ✅ 调查完成（仅 2 分钟） |

### 场景 4：DB 连接失败

| 项目 | 内容 |
|---|---|
| **CronJob** | `chaos-db-exhaust` |
| **文件** | `k8s/chaos-db-exhaust.yaml` |
| **Schedule** | `0 5,13,21 * * *`（每 8 小时） |
| **注入方式** | Patch Deployment 注入 `DATABASE_URL=postgres://outline:fake@10.255.255.1:5432/outline`（不可达地址） |
| **故障表现** | Pod 启动时 DB 连接超时 → 进程退出 → CrashLoopBackOff |
| **触发告警** | `OutlinePodCrashLooping` (critical) |
| **Agent 调查重点** | CloudWatch 显示 RDS 完全健康（连接数正常、CPU 正常），但应用连不上 → 需要检查 Deployment 变更历史，发现 DATABASE_URL 被覆盖为错误地址 |
| **自动恢复** | `kubectl rollout undo` |
| **验证 Issue** | #19 ✅ 调查启动 |

---

## 连锁反应时间线（以 Redis 场景实测数据为例）

```
T+0:00   CronJob 启动
         ├── NetworkPolicy block-redis 创建
         └── Deployment patch 注入 bad REDIS_URL → 滚动更新

T+0:30   新 Pod 启动，日志：Redis error: connect ETIMEDOUT
         容器退出 → kubelet 重启 → CrashLoopBackOff

T+4:00   restart rate = 4.06/15min，超过阈值 >3
         Prometheus 规则 OutlinePodCrashLooping 进入 pending

T+9:00   pending 持续满 5 分钟，告警转为 firing (severity: critical)
         Alertmanager 收到告警

T+9:30   Alertmanager → SNS 发送纯文本告警消息
         SNS → Lambda feishu-notifier 触发

T+9:31   Lambda 执行：
         ├── 关闭旧 Issue #9 (OutlinePodCrashLooping)
         ├── 创建新 Issue #13 [CRITICAL] OutlinePodCrashLooping
         └── 飞书群发送告警卡片

T+9:35   GitHub Actions 监听到 issues.opened
         构建 incident payload，HMAC 签名
         POST → DevOps Agent Webhook

T+9:46   Issue #13 评论："DevOps Agent 调查已触发"

T+10:05  Issue #13 评论："调查已创建，排队中 (Pending)"

T+10:16  Issue #13 评论："调查进行中 (In Progress)" + Operator Web URL
         Agent 开始关联数据源：
         ├── Grafana/Prometheus：发现 Pod restart rate 异常
         ├── Grafana/OpenSearch：发现 "Redis error: connect ETIMEDOUT"
         ├── CloudWatch：发现 ElastiCache Redis 本身健康（关键矛盾点）
         └── GitHub：检查最近的 deployment 变更

T+13:46  Issue #13 评论："✅ 调查完成" + 根因摘要

T+8:00   CronJob Phase 4：rollback + 删除 NetworkPolicy
         Pod 恢复正常，告警自动 resolve
```

从故障注入到 Agent 完成调查，全程约 **14 分钟**，全自动无人干预。

---

## 搭建过程中修复的 3 个问题

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| 1 | Alertmanager → SNS 100% 失败（持续 10 天） | `sns_configs` 缺少 `subject` 字段，默认生成的 Subject 超过 SNS 100 字符限制 | 添加 `subject: "Outline Alert"`，热修复 K8s Secret + 同步 Terraform |
| 2 | Lambda `JSONDecodeError` 崩溃 | Alertmanager SNS 发纯文本不是 JSON，`json.loads()` 失败 | 增加纯文本解析分支，用正则提取 alertname/severity/summary |
| 3 | DevOps Agent 不触发调查 | Lambda 找到同名 open Issue 只追加评论，不触发 `issues.opened` 事件 | 改为先关闭旧 Issue 再创建新 Issue，确保每次都触发 GitHub Actions |

---

## 已知限制

**Alertmanager `repeat_interval: 4h`**：同一个告警名（`OutlinePodCrashLooping`）在 4 小时内只会发送一次 SNS。如果多个场景在 4 小时内连续触发，只有第一个会自动创建 Issue。后续场景需要手动 `aws sns publish` 触发。解决方案：缩短 `repeat_interval` 或为每个场景设计不同的告警名。

**`rollout undo` 偶尔卡住**：当 Deployment 有多个 revision 历史时，`rollout undo` 可能回滚到错误的 revision（仍带有注入的 env）。CronJob 中已设置 `activeDeadlineSeconds: 900` 防止无限等待，但可能需要手动 patch 恢复原始配置。

---

## 修改的文件

| 文件 | 变更 |
|---|---|
| `terraform/modules/observability/main.tf` | Alertmanager sns_configs 添加 `subject = "Outline Alert"` |
| `terraform/modules/integration/lambda/feishu_notifier.py` | 增加纯文本消息解析 + 关闭旧 Issue 再创建新 Issue |
| `k8s/chaos-cronjob.yaml` | CronJob + RBAC：Redis 级联故障 |
| `k8s/chaos-dns-failure.yaml` | CronJob：DNS 解析故障 |
| `k8s/chaos-oom-kill.yaml` | CronJob：OOM Kill 内存不足 |
| `k8s/chaos-db-exhaust.yaml` | CronJob：DB 连接失败 |
