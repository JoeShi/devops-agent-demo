# AWS DevOps Agent 演示方案

## 演示主线

围绕 DevOps Agent 的三大核心能力设计 5 个场景，形成递进式故事线：

```
场景 1-3：自动化事件调查（核心卖点）
场景 4：  对话式交互（Chat）
场景 5：  预防建议（Prevention）
```

## 演示顺序

| 顺序 | 场景 | 方式 | 时长 | 核心信息 |
|------|------|------|------|----------|
| 1 | 场景 4：Chat 对话式交互 | 现场 | 5 min | 暖场，展示 Agent 对环境的理解 |
| 2 | 场景 1：DB 连接池耗尽 | 预录 | 8 min | 核心能力：自动调查 + 多源关联 |
| 3 | 场景 3：Redis 级联故障 | 现场注入 + 预录 | 8 min | 进阶：拓扑感知 + 告警去重 |
| 4 | 场景 2：坏部署延迟飙升 | 预录 | 5 min | 部署关联 + 代码追溯 |
| 5 | 场景 5：预防建议 | 现场 | 5 min | 闭环：从救火到预防 |

总时长约 **30 分钟**。

---

## 场景 1：DB 连接池耗尽

**展示能力**：自动化调查 + 多数据源关联 + 根因分析

**故事**：Outline 突然返回大量 500 错误，用户无法访问。

### 注入方式

```bash
./scripts/chaos.sh db-exhaust
```

### 触发链路

```
pgbench Job 占满 DB 连接
  → Outline 返回 500
  → Prometheus 检测 5xx 错误率 > 5%
  → Grafana Alert: OutlineHighErrorRate 触发
  → Webhook 通知 DevOps Agent
  → Agent 自动创建调查
```

### 调查过程（预录）

1. Agent 查询 Grafana/Prometheus → 发现 5xx 率 38%，14:03 开始飙升
2. Agent 查询 Grafana/OpenSearch → 发现 `SequelizeConnectionError: too many clients`
3. Agent 查询 CloudWatch → 发现 RDS DatabaseConnections = 100/100（满）
4. Agent 关联 EKS Pod 状态 → 发现 Worker CrashLoopBackOff

### 根因摘要

DB 连接池耗尽。100 个空闲连接占满了 RDS 最大连接数，导致应用无法获取新连接。

### 修复建议

- 增加 RDS max_connections 或使用 RDS Proxy
- 配置 idle_in_transaction_session_timeout 清理空闲连接
- 添加 CloudWatch 告警：DatabaseConnections > 80%

### 清理

```bash
./scripts/chaos.sh db-exhaust --cleanup
```

---

## 场景 2：坏部署导致延迟飙升

**展示能力**：部署关联 + 时间线分析 + 回滚建议

**故事**：一次部署后 API 延迟从 200ms 飙升到 5s。

### 注入方式

```bash
./scripts/chaos.sh slow-deploy
```

### 触发链路

```
Sidecar 注入，阻断 DB 连接（iptables REJECT）
  → Outline API 超时
  → Prometheus 检测 P99 延迟 > 2s
  → Grafana Alert: OutlineHighLatency 触发
  → Agent 自动调查
```

### 调查过程（预录）

1. Agent 查询延迟指标 → P99 从 200ms 飙到 5000ms
2. Agent 关联 GitHub 部署记录 → 定位到具体 commit/deployment
3. Agent 分析部署变更内容 → 发现新增的 sidecar 阻断了 DB 连接
4. Agent 对比部署前后指标 → 确认延迟飙升与部署时间完全吻合

### 根因摘要

最近一次部署引入了 latency-injector sidecar，该容器通过 iptables 规则阻断了到 PostgreSQL 5432 端口的连接，导致所有数据库查询超时。

### 修复建议

- 立即回滚：`kubectl rollout undo deployment/outline-web`
- 在 CI 中增加部署后延迟回归测试
- 配置部署后自动 canary 检查

### 清理

```bash
./scripts/chaos.sh slow-deploy --cleanup
```

---

## 场景 3：Redis 级联故障

**展示能力**：拓扑感知 + 告警去重 + 级联分析

**故事**：Redis 不可用，同时触发多个告警（WebSocket 断连、缓存失效、DB 负载飙升）。

### 注入方式

```bash
./scripts/chaos.sh redis-failure
```

### 触发链路

```
NetworkPolicy 阻断 Redis 6379 端口
  → WebSocket 断连（Redis pub/sub 失败）
  → 缓存失效（所有请求打到 DB）
  → DB 负载飙升
  → 多个告警同时触发
  → Agent 收到多个告警，开始调查
```

### 调查过程（预录）

1. Agent 收到多个告警（WebSocket 断连、DB 负载高、5xx 错误），自动去重
2. Agent 利用 Topology 理解依赖关系：Redis → WebSocket + Cache → PostgreSQL
3. Agent 查询 ElastiCache 指标 → 发现 Redis 连接数骤降为 0
4. Agent 识别 Redis 是根因，而非 DB 或 WebSocket

### 根因摘要

Redis 网络不可达（NetworkPolicy 阻断了 6379 端口出站流量）。WebSocket 依赖 Redis pub/sub 进行实时同步，缓存层依赖 Redis 存储会话和热点数据。Redis 故障导致：
1. WebSocket 断连 → 实时协作失败
2. 缓存穿透 → 所有请求直接打到 PostgreSQL
3. DB 负载飙升 → 部分请求超时返回 500

### 修复建议

- 检查 NetworkPolicy 配置，恢复 Redis 出站流量
- 应用层增加 Redis 降级逻辑（缓存不可用时直接查 DB）
- 配置 ElastiCache 连接数告警

### 演示亮点

现场注入后，可以展示飞书群同时收到多条告警卡片，体现"告警风暴"场景。然后切到 Agent 调查页面，展示 Agent 如何从多个告警中识别出 Redis 是真正的根因。

### 清理

```bash
./scripts/chaos.sh redis-failure --cleanup
```

---

## 场景 4：对话式交互（Chat）

**展示能力**：DevOps Agent Chat + 自然语言查询基础设施

**方式**：在 DevOps Agent Web App 中现场对话，或通过飞书 Bot 交互。

### 演示对话（Web App）

| 问题 | 展示能力 |
|------|----------|
| "Outline 应用当前健康状态如何？" | 环境感知，综合判断 |
| "过去 24 小时有哪些异常？" | 历史事件回顾 |
| "帮我查看 RDS 连接数趋势" | 自然语言查询指标 |
| "哪些资源和 outline-web 有依赖关系？" | Topology 理解 |
| "最近一次部署是什么时候？改了什么？" | 部署历史查询 |

### 演示对话（飞书 Bot）

在飞书群中 @Bot：
- "Outline 应用当前健康状态如何？"
- "帮我查看 RDS 连接数趋势"

展示 Bot 通过 DevOps Agent Chat API 返回结果。

### 演示亮点

- 不需要切换多个控制台（CloudWatch、Grafana、kubectl）
- 自然语言即可查询基础设施状态
- Chat 具有上下文感知，支持追问

---

## 场景 5：预防建议（Prevention）

**展示能力**：Ops Backlog + 持续改进闭环

**前置条件**：场景 1-3 的调查完成后，Agent 已积累足够数据。

### 演示流程

1. 打开 DevOps Agent Web App → **Ops Backlog** 页面
2. 展示 Agent Summary：分析了 N 次调查，生成了 M 条建议
3. 展示建议分类饼图（四个分类）：
   - **Observability**：增加 RDS 连接数阈值告警、补充 Redis 健康检查 Dashboard
   - **Infrastructure**：配置 HPA、增加连接池限制、Redis 降级策略
   - **Governance**：在 CI 中增加性能回归测试、部署后 canary 检查
   - **Code**：优化慢查询、增加连接超时配置
4. 点开一条建议，展示详情：
   - 关联的历史事件
   - 预期影响
   - Agent-ready Specification（可直接交给编码 Agent 实施）
5. 演示 Keep / Discard / Implemented 工作流
   - Discard 时提供反馈，Agent 学习并优化后续建议

### 演示亮点

- 从被动救火到主动预防
- 基于真实事件数据的针对性建议，不是通用 checklist
- Agent-ready Spec 可直接交给编码 Agent 实施，形成自动化闭环

---

## 环境准备 Checklist

### 演示前

- [ ] 确认 EKS 集群健康（所有 Pod Running，0 重启）
- [ ] 确认 Grafana 可访问（https://grafana.devops-agent.xyz）
- [ ] 确认 Outline 可访问（https://outline.devops-agent.xyz）
- [ ] 确认 DevOps Agent Space 已配置（Grafana + GitHub + CloudWatch）
- [ ] 确认飞书 Bot 在线（WebSocket 已连接）
- [ ] 确认 Grafana Alert 规则已部署（7 条规则）
- [ ] 确认 Grafana → DevOps Agent Webhook Contact Point 已配置
- [ ] 预录场景 1、2、3 的调查过程（截图/录屏）
- [ ] 准备 chaos.sh 脚本（场景 3 现场注入用）

### 演示后

- [ ] 清理所有故障注入
  ```bash
  ./scripts/chaos.sh db-exhaust --cleanup
  ./scripts/chaos.sh slow-deploy --cleanup
  ./scripts/chaos.sh redis-failure --cleanup
  ```
- [ ] 确认集群恢复健康
