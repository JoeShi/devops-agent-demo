# 🎯 DevOps Agent Demo Runbook

> 本页面用于演示 AWS DevOps Agent 的自动事件调查能力。点击触发链接注入故障，然后跟随时间线观察 Agent 如何自动定位根因。

## 快速链接

| 资源 | 链接 |
|---|---|
| 📊 Grafana Dashboard | [Outline App Overview](https://grafana.devops-agent.xyz/d/outline-app-overview) |
| 🎫 GitHub Issues（工单） | [devops-agent-demo-tickets](https://github.com/JoeShi/devops-agent-demo-tickets/issues) |
| 🤖 DevOps Agent Web App | [Operator Web](https://9e3ca279-9252-4dd8-b19f-1ca9cb7c8439.aidevops.global.app.aws) |
| 📈 Prometheus Alerts | [Grafana Alerting](https://grafana.devops-agent.xyz/alerting/list) |
| 🔍 环境状态 | [查看当前状态](https://alb-outline.devops-agent.xyz/chaos/status) |

---

## 场景 1：Redis 级联故障 🔴

**故事**：Redis 连接配置被错误修改，应用无法连接缓存层，持续崩溃重启。

**Agent 调查重点**：CloudWatch 显示 ElastiCache Redis 完全健康，但应用日志显示 `ETIMEDOUT`。Agent 需要发现是配置变更（REDIS_URL 被篡改）而非 Redis 本身故障。

### 👉 [点击触发 Redis 故障](https://alb-outline.devops-agent.xyz/chaos/trigger/redis-failure)

### 预期时间线

| 时间 | 事件 | 去哪里看 |
|---|---|---|
| T+0:30 | Pod 开始 CrashLoopBackOff | [环境状态](https://alb-outline.devops-agent.xyz/chaos/status) |
| T+4:00 | Prometheus 告警 pending | [Grafana Alerting](https://grafana.devops-agent.xyz/alerting/list) |
| T+9:00 | 告警 firing → 飞书通知 | 飞书群 |
| T+9:30 | GitHub Issue 自动创建 | [GitHub Issues](https://github.com/JoeShi/devops-agent-demo-tickets/issues) |
| T+10:00 | DevOps Agent 调查开始 | Issue 评论中的 Operator Web 链接 |
| T+14:00 | ✅ 调查完成，根因摘要写回 Issue | Issue 评论 |
| T+12:00 | 环境自动恢复 | [环境状态](https://alb-outline.devops-agent.xyz/chaos/status) |

### 观察要点

1. 打开 [Grafana Dashboard](https://grafana.devops-agent.xyz/d/outline-app-overview) → 观察 Pod Restart Rate 飙升
2. 打开 [GitHub Issues](https://github.com/JoeShi/devops-agent-demo-tickets/issues) → 等待新 Issue 出现
3. 点击 Issue 中的 **Operator Web 链接** → 实时观看 Agent 调查过程
4. Agent 完成后查看根因摘要 — 应该识别出 `REDIS_URL` 被篡改为不可达地址

---

## 场景 2：DNS 解析故障 🟡

**故事**：DNS 配置异常，所有域名解析失败，应用无法连接任何外部依赖。

**Agent 调查重点**：最有迷惑性 — RDS 和 Redis 在 CloudWatch 中都完全健康，但应用日志显示 `getaddrinfo EAI_AGAIN`。Agent 需要深入到 DNS 层排查。

### 👉 [点击触发 DNS 故障](https://alb-outline.devops-agent.xyz/chaos/trigger/dns-failure)

### 预期时间线

| 时间 | 事件 | 去哪里看 |
|---|---|---|
| T+0:30 | Pod CrashLoop，日志 `getaddrinfo EAI_AGAIN` | [环境状态](https://alb-outline.devops-agent.xyz/chaos/status) |
| T+3:00 | OutlineDNSFailure 告警 pending | [Grafana Alerting](https://grafana.devops-agent.xyz/alerting/list) |
| T+6:00 | 告警 firing → Issue 创建 | [GitHub Issues](https://github.com/JoeShi/devops-agent-demo-tickets/issues) |
| T+7:00 | Agent 调查开始 | Operator Web |
| T+10:00 | 环境自动恢复 | [环境状态](https://alb-outline.devops-agent.xyz/chaos/status) |

### 观察要点

1. 注意日志中的 `EAI_AGAIN` — DNS 解析失败的标志
2. 对比 CloudWatch RDS/Redis 指标 — 全部正常（Agent 需要识别的矛盾点）

---

## 场景 3：OOM Kill（内存不足）🟠

**故事**：容器内存限制被错误调低，应用启动即超限被 OOM Kill。

**Agent 调查重点**：识别 OOM Kill 模式（exit code 137）与其他 CrashLoop 的区别。

### 👉 [点击触发 OOM Kill](https://alb-outline.devops-agent.xyz/chaos/trigger/oom-kill)

⭐ **推荐首选演示** — 最快出结果，Agent 约 2 分钟完成调查。

### 预期时间线

| 时间 | 事件 | 去哪里看 |
|---|---|---|
| T+0:30 | Pod OOM Kill (exit 137) | [环境状态](https://alb-outline.devops-agent.xyz/chaos/status) |
| T+1:00 | OutlinePodOOMKilled 告警 pending | [Grafana Alerting](https://grafana.devops-agent.xyz/alerting/list) |
| T+2:00 | 告警 firing → Issue 创建 | [GitHub Issues](https://github.com/JoeShi/devops-agent-demo-tickets/issues) |
| T+2:30 | Agent 调查开始 | Operator Web |
| T+4:30 | ✅ **调查完成**（最快，~2min） | Issue 评论 |
| T+10:00 | 环境自动恢复 | [环境状态](https://alb-outline.devops-agent.xyz/chaos/status) |

### 观察要点

1. [环境状态](https://alb-outline.devops-agent.xyz/chaos/status) 中注意 `OOMKilled` 状态
2. [Grafana Dashboard](https://grafana.devops-agent.xyz/d/outline-app-overview) → 内存使用图 → 瞬间打满
3. 这是 Agent 调查最快的场景（~2 分钟），因为 OOM Kill 信号非常明确

---

## 场景 4：DB 连接失败 🔵

**故事**：数据库连接字符串被错误修改，应用无法连接 PostgreSQL。

**Agent 调查重点**：CloudWatch 显示 RDS 完全健康，但应用连不上。Agent 需要检查 Deployment 变更历史。

### 👉 [点击触发 DB 故障](https://alb-outline.devops-agent.xyz/chaos/trigger/db-exhaust)

### 预期时间线

| 时间 | 事件 | 去哪里看 |
|---|---|---|
| T+1:00 | Pod CrashLoop，DB 连接超时 | [环境状态](https://alb-outline.devops-agent.xyz/chaos/status) |
| T+5:00 | OutlineDBConnectionFailure 告警 firing | [Grafana Alerting](https://grafana.devops-agent.xyz/alerting/list) |
| T+6:00 | Issue 创建 → Agent 调查开始 | [GitHub Issues](https://github.com/JoeShi/devops-agent-demo-tickets/issues) |
| T+10:00 | 环境自动恢复 | [环境状态](https://alb-outline.devops-agent.xyz/chaos/status) |

---

## 🧹 紧急清理

如果需要立即恢复环境（不等自动恢复）：

### 👉 [点击立即清理](https://alb-outline.devops-agent.xyz/chaos/cleanup)

---

## 演示建议

1. **开场**：先展示 Outline 正常运行，打开 [Grafana Dashboard](https://grafana.devops-agent.xyz/d/outline-app-overview) 展示健康指标
2. **选择场景**：推荐从 **场景 3 OOM Kill** 开始（最快，2 分钟出结果），然后演示 **场景 1 Redis**（最完整的因果链分析）
3. **触发后**：打开 [GitHub Issues](https://github.com/JoeShi/devops-agent-demo-tickets/issues) 等待新 Issue 出现，然后点击 Operator Web 链接实时观看 Agent 调查
4. **讲解**：重点展示 Agent 如何跨数据源关联（Prometheus 指标 + OpenSearch 日志 + CloudWatch + GitHub 变更），以及最终的根因摘要
5. **对比**：如果时间允许，连续演示两个场景，展示 Agent 对不同故障模式的区分能力
