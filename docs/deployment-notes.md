# Deployment Notes & Gotchas

Lessons learned from full deployment testing. Read this before deploying to a new AWS account.

## Prerequisites Checklist

- [ ] AWS account with sufficient quotas (EIP ≥ 3, NAT Gateway, EKS)
- [ ] Route53 hosted zone with NS records delegated from domain registrar
- [ ] GitHub Actions OIDC provider created: `aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1`
- [ ] ECR repositories created: `outline`, `outline-base`, `feishu-bot`, `wecom-bot`, `dingtalk-bot`
- [ ] Docker Desktop (or Finch) for building Bot images
- [ ] Terraform >= 1.5.0, kubectl, helm installed

## Hard-Coded Values to Update

### terraform/main.tf — Backend Configuration

```hcl
backend "s3" {
  bucket         = "outline-terraform-state-<YOUR_ACCOUNT_ID>"  # Change this
  ...
}
```

### terraform.tfvars — All Environment-Specific Values

Copy `terraform.tfvars.example` and fill in your values. Key fields:
- `db_password`, `grafana_admin_password`, `opensearch_master_password` — strong passwords
- `outline_domain`, `route53_zone_name`, `grafana_host` — your domain
- `devops_agent_space_id` — from AWS Console after creating Agent Space
- `alb_dns_name`, `grafana_alb_dns_name` — set after first `kubectl apply` creates ALB

### K8s Manifests — Account ID & Domain

All K8s YAML files reference the original account `604179600882`. After `terraform apply`, update:
- `k8s/external-secret.yaml` — IRSA role ARN
- `k8s/feishu-bot-deployment.yaml` — IRSA role ARN + ECR image URI
- `k8s/wecom-bot-deployment.yaml` — IRSA role ARN + ECR image URI
- `k8s/dingtalk-bot-deployment.yaml` — IRSA role ARN + ECR image URI
- `k8s/ingress.yaml` — ACM certificate ARN + domain hosts
- `k8s/deployment.yaml` — `URL` env var (Outline application URL)

Use `terraform output` to get the correct values:
```bash
terraform output feishu_bot_role_arn    # → IRSA role ARN for feishu-bot
terraform output eks_cluster_name       # → for ECR image URI pattern
```

## Deployment Order (Critical)

Terraform resources have cross-module dependencies. Deploy in this order:

1. `terraform apply` — creates VPC, EKS, RDS, Redis, but **OpenSearch may fail on first run** (see below)
2. Wait for OpenSearch to complete, then `terraform apply` again — this time Helm releases will be included
3. `kubectl apply -k k8s/` — deploy Outline application
4. Get ALB DNS from `kubectl get ingress -n outline`, update `terraform.tfvars`
5. `terraform apply` — updates Route53/CloudFront to point to ALB
6. Build and push Bot images, then `kubectl apply` Bot deployments

## Known Gotchas

### 1. OpenSearch: Even Number of Nodes Required

**Error**: `You must choose an even number of data nodes for a two Availability Zone deployment`

**Cause**: VPC has 2 AZs, OpenSearch requires even node count.

**Fix**: Set `opensearch_instance_count = 2` (not 1) in tfvars.

### 2. Helm Releases Not in Plan

**Symptom**: `terraform apply` creates infrastructure but skips `helm_release` resources.

**Root Cause**: `module.observability` inputs depend on `opensearch_endpoint` output. If OpenSearch creation fails, the endpoint is unknown, and Terraform skips the entire module's Helm resources.

**Fix**: Ensure OpenSearch succeeds first, then re-run `terraform apply`.

### 3. Cognito Domain Globally Unique

**Error**: `Domain already associated with another user pool`

**Cause**: Cognito custom domains are globally unique across all AWS accounts. The default `outline-demo-auth` may be taken.

**Fix**: The code appends account ID to domain name: `${project_name}-auth-${account_id}`.

### 4. CloudFront Origin Resolution

**Error**: `CloudFront wasn't able to resolve the origin domain name` (502)

**Cause**: CloudFront origin is `alb-<domain>` (a subdomain), not the ALB DNS directly. This subdomain must resolve to the ALB.

**Fix**: Ensure `alb_dns_name` in tfvars is set to the real ALB DNS. Terraform creates a CNAME `alb-<domain> → <ALB_DNS>`.

### 5. Ingress Must Match CloudFront Origin Host

**Symptom**: HTML loads but static assets return 404.

**Cause**: CloudFront sends requests with `Host: alb-<domain>`, but Ingress only matches `<domain>`.

**Fix**: Add both hosts to Ingress rules:
```yaml
rules:
  - host: outline.example.com        # Direct access
  - host: alb-outline.example.com    # CloudFront origin
```

### 6. DingTalk Stream Subscription Type

**Error**: Bot connects to Stream but never receives messages.

**Cause**: Gateway subscription must use `"type": "CALLBACK"`, not `"type": "EVENT"`.

**Fix**: In `k8s/dingtalk-bot/app.py`:
```python
"subscriptions": [
    {"type": "CALLBACK", "topic": "/v1.0/im/bot/messages/get"},
]
```

### 7. EKS Node Capacity

**Symptom**: Pods stuck in `Pending` state.

**Cause**: 2x t3.medium nodes insufficient for full stack (Outline 3 replicas + Worker + 3 Bots + ESO + LB Controller + Prometheus).

**Fix**: Use at least 3 nodes, or use larger instance types. Scale with:
```bash
aws eks update-nodegroup-config --cluster-name <name> --nodegroup-name <ng> \
  --scaling-config minSize=2,maxSize=4,desiredSize=3
```

### 8. AWS Load Balancer Controller VPC ID

**Error**: `failed to get VPC ID from instance metadata`

**Cause**: LB Controller can't access EC2 instance metadata on some EKS configurations.

**Fix**: Pass `--set vpcId=<VPC_ID> --set region=<REGION>` when installing via Helm.

### 9. Terraform State Lock Conflicts

**Symptom**: `Error acquiring the state lock`

**Cause**: Previous interrupted `terraform apply` left a stale lock in DynamoDB.

**Fix**: `terraform force-unlock -force <LOCK_ID>`

### 10. Dockerfile Base Image

**Tip**: If Docker Hub (`docker.io`) is unreachable from your network, use AWS ECR Public mirror:
```dockerfile
FROM public.ecr.aws/docker/library/python:3.12-slim
```

## Secrets Manager Layout

| Secret Name | Contents | Used By |
|-------------|----------|---------|
| `outline/production` | DATABASE_URL, REDIS_URL, SECRET_KEY, UTILS_SECRET | Outline app |
| `outline/feishu-bot` | FEISHU_APP_ID, FEISHU_APP_SECRET, DEVOPS_AGENT_SPACE_ID | Feishu Bot |
| `outline/wecom-bot` | WECOM_BOT_ID, WECOM_BOT_SECRET, DEVOPS_AGENT_SPACE_ID | WeCom Bot |
| `outline/dingtalk-bot` | DINGTALK_APP_KEY, DINGTALK_APP_SECRET, DEVOPS_AGENT_SPACE_ID | DingTalk Bot |
| `outline/github-token` | GitHub PAT | Lambda (issue management) |
| `grafana-devops-agent-token` | Grafana SA token | DevOps Agent integration |
