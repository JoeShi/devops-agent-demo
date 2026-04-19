#!/usr/bin/env bash
# Verify the end-to-end alert → GitHub Issue → DevOps Agent investigation pipeline.
#
# Usage:
#   ./verify-pipeline.sh check              # Stage 1: passive prerequisite checks (safe, read-only)
#   ./verify-pipeline.sh fire [TITLE]       # Stage 2: create a test issue and observe the pipeline
#   ./verify-pipeline.sh watch ISSUE_NUM    # Follow-up: poll state for an existing issue
#   ./verify-pipeline.sh cleanup ISSUE_NUM  # Close the test issue
#
# Environment overrides:
#   AWS_REGION          default: us-east-1
#   TICKETS_REPO        default: JoeShi/devops-agent-demo-tickets
#   AGENT_SPACE_ID      default: read from terraform/terraform.tfvars
#   WEBHOOK_SECRET_ID   default: /devops-agent/agent-space-webhook
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
TICKETS_REPO="${TICKETS_REPO:-JoeShi/devops-agent-demo-tickets}"
WEBHOOK_SECRET_ID="${WEBHOOK_SECRET_ID:-/devops-agent/agent-space-webhook}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# colors
red()    { printf "\033[0;31m%s\033[0m\n" "$*"; }
green()  { printf "\033[0;32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[0;33m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }

ok()   { green  "  ✅ $*"; }
warn() { yellow "  ⚠️  $*"; }
fail() { red    "  ❌ $*"; PASS=0; }
step() { bold   "── $* ──"; }

PASS=1

# Resolve Agent Space ID (env > tfvars)
if [[ -z "${AGENT_SPACE_ID:-}" ]]; then
  if [[ -f "${ROOT_DIR}/terraform/terraform.tfvars" ]]; then
    AGENT_SPACE_ID=$(awk -F'"' '/^[[:space:]]*devops_agent_space_id[[:space:]]*=/{print $2; exit}' \
      "${ROOT_DIR}/terraform/terraform.tfvars" || true)
  fi
fi

need() {
  command -v "$1" >/dev/null 2>&1 || { red "Missing required CLI: $1"; exit 2; }
}

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# ─── Stage 1: prerequisite checks ───────────────────────────────────────────
cmd_check() {
  need aws; need gh; need jq

  step "Identity & region"
  aws sts get-caller-identity --output json \
    | jq -r '"  Account: \(.Account)\n  ARN: \(.Arn)"' \
    || fail "aws sts get-caller-identity failed"
  echo "  Region: ${AWS_REGION}"
  echo "  Tickets repo: ${TICKETS_REPO}"
  if [[ -n "${AGENT_SPACE_ID:-}" ]]; then
    ok "Agent Space ID: ${AGENT_SPACE_ID}"
  else
    warn "Agent Space ID not resolved (set AGENT_SPACE_ID env or terraform.tfvars)"
  fi

  step "① Grafana associated with DevOps Agent"
  if aws ssm get-parameter --name /devops-agent/grafana-service-id \
       --region "${AWS_REGION}" --query 'Parameter.Value' --output text >/dev/null 2>&1; then
    ok "SSM /devops-agent/grafana-service-id present"
  else
    fail "SSM parameter /devops-agent/grafana-service-id missing → Grafana not registered"
  fi

  step "② Agent Space Webhook credentials in Secrets Manager"
  if aws secretsmanager describe-secret --secret-id "${WEBHOOK_SECRET_ID}" \
       --region "${AWS_REGION}" >/dev/null 2>&1; then
    ok "Secret ${WEBHOOK_SECRET_ID} present"
  else
    fail "Secret ${WEBHOOK_SECRET_ID} missing — run scripts/capture-webhook-creds.sh"
  fi

  step "③ Lambda: investigation-notifier"
  if aws lambda get-function --function-name investigation-notifier \
       --region "${AWS_REGION}" \
       --query 'Configuration.{State:State,LastModified:LastModified,Runtime:Runtime,CodeSize:CodeSize}' \
       --output table 2>/dev/null; then
    ok "Lambda investigation-notifier deployed"
  else
    fail "Lambda investigation-notifier not found"
  fi

  step "④ Lambda: feishu-notifier"
  if aws lambda get-function --function-name feishu-notifier \
       --region "${AWS_REGION}" \
       --query 'Configuration.{State:State,LastModified:LastModified}' \
       --output table 2>/dev/null; then
    ok "Lambda feishu-notifier deployed"
  else
    fail "Lambda feishu-notifier not found"
  fi

  step "⑤ EventBridge rule: devops-agent-investigation-to-github"
  local state
  state=$(aws events describe-rule --name devops-agent-investigation-to-github \
            --region "${AWS_REGION}" --query 'State' --output text 2>/dev/null || echo "")
  if [[ "$state" == "ENABLED" ]]; then
    ok "EventBridge rule ENABLED"
  elif [[ -n "$state" ]]; then
    warn "EventBridge rule exists but state=$state"
  else
    fail "EventBridge rule not found"
  fi

  step "⑥ Tickets repo workflow: .github/workflows/trigger-investigation.yml"
  if gh api "repos/${TICKETS_REPO}/contents/.github/workflows/trigger-investigation.yml" \
       --jq '.name' >/dev/null 2>&1; then
    ok "trigger-investigation.yml exists in ${TICKETS_REPO}"
  else
    fail "Workflow file missing or repo inaccessible (gh auth?)"
  fi

  step "⑦ Tickets repo secrets: DEVOPS_AGENT_WEBHOOK_URL / SECRET"
  if gh secret list --repo "${TICKETS_REPO}" 2>/dev/null | grep -qE '^DEVOPS_AGENT_WEBHOOK_URL\b'; then
    ok "GitHub secrets configured"
  else
    warn "Cannot list secrets (PAT lacks 'Secrets: Read'); verify manually at https://github.com/${TICKETS_REPO}/settings/secrets/actions"
  fi

  echo
  if [[ $PASS -eq 1 ]]; then
    green "All checks passed. Ready to run: $0 fire"
  else
    red "Some checks failed; resolve the ⚠️  / ❌ items above before firing a test."
    exit 1
  fi
}

# ─── Stage 2: fire a synthetic issue ────────────────────────────────────────
cmd_fire() {
  need gh; need aws; need jq
  local title="${1:-[TEST] Outline 500 error spike - pipeline verification $(date +%Y%m%d-%H%M%S)}"

  step "Creating test issue in ${TICKETS_REPO}"
  local issue_url
  issue_url=$(gh issue create \
    --repo "${TICKETS_REPO}" \
    --title "$title" \
    --body "**Severity:** critical
**Status:** firing
**Summary:** Synthetic ticket for verifying alert→issue→investigation→comment pipeline.

This is a test created by \`scripts/verify-pipeline.sh fire\`. Safe to ignore/close.

[View Dashboard](https://grafana.devops-agent.xyz)" \
    --label "incident,critical")
  ok "Created: $issue_url"
  local issue_num="${issue_url##*/}"
  echo "Issue number: $issue_num"
  echo
  echo "Next: $0 watch $issue_num"
}

# ─── Stage 3: watch progress of a given issue ───────────────────────────────
# With the Agent Space Webhook design, there is NO SSM mapping — the mapping
# is stateless: workflow sends incidentId=<repo>#<number>, DevOps Agent stores
# it as reference.referenceId on the task, and the Lambda reads it back.
cmd_watch() {
  need gh; need aws; need jq
  local issue_num="${1:?Usage: $0 watch ISSUE_NUM}"
  local incident_id="${TICKETS_REPO}#${issue_num}"

  step "① GitHub Actions workflow runs (last 3)"
  gh run list --repo "${TICKETS_REPO}" \
    --workflow trigger-investigation.yml --limit 3 \
    --json databaseId,status,conclusion,createdAt,headBranch \
    --jq '.[] | "  \(.createdAt)  \(.status)/\(.conclusion // "-")  runId=\(.databaseId)"' \
    || warn "Cannot list workflow runs"

  step "② DevOps Agent backlog task with referenceId=${incident_id}"
  # Look up the task by referenceId via list-backlog-tasks
  local task_json task_id task_status primary_task_id
  task_json=$(aws devops-agent list-backlog-tasks \
      --region "${AWS_REGION}" \
      --agent-space-id "${AGENT_SPACE_ID:-}" \
      --query "tasks[?reference.referenceId=='${incident_id}'] | [0]" \
      --output json 2>/dev/null || echo "null")

  if [[ "$task_json" == "null" || -z "$task_json" ]]; then
    warn "No backlog task found with referenceId=${incident_id} yet (webhook may still be processing)"
  else
    task_id=$(echo "$task_json"       | jq -r '.taskId')
    task_status=$(echo "$task_json"   | jq -r '.status')
    primary_task_id=$(echo "$task_json" | jq -r '.primaryTaskId // empty')
    echo "  Task ID:   ${task_id}"
    echo "  Status:    ${task_status}"
    [[ -n "$primary_task_id" ]] && echo "  Linked to primary: ${primary_task_id}"

    if [[ -n "${AGENT_SPACE_ID:-}" ]]; then
      local target_task_id="${primary_task_id:-$task_id}"
      bold "  👁 Operator Web: https://${AGENT_SPACE_ID}.aidevops.global.app.aws/${AGENT_SPACE_ID}/investigation/${target_task_id}"
    fi
  fi

  step "③ investigation-notifier Lambda logs (last 10 min, matching #${issue_num})"
  aws logs tail /aws/lambda/investigation-notifier \
    --since 10m --region "${AWS_REGION}" 2>/dev/null \
    | grep -E "Posted comment.*${TICKETS_REPO}#${issue_num}|referenceId.*${issue_num}|ERROR" \
    | tail -15 \
    || warn "No Lambda log lines yet for issue #${issue_num}"

  step "④ GitHub issue comments (#${issue_num})"
  gh api "repos/${TICKETS_REPO}/issues/${issue_num}/comments" \
    --jq '.[] | "  [\(.created_at)] " + (.body | split("\n")[0])' 2>&1 \
    | head -30
}

# ─── Cleanup ────────────────────────────────────────────────────────────────
cmd_cleanup() {
  need gh
  local issue_num="${1:?Usage: $0 cleanup ISSUE_NUM}"
  gh issue close "$issue_num" --repo "${TICKETS_REPO}" \
    --comment "Pipeline verification complete. Closing test ticket."
  ok "Closed issue #${issue_num}"
}

# ─── Dispatch ───────────────────────────────────────────────────────────────
[[ $# -lt 1 ]] && usage
case "$1" in
  check)   shift; cmd_check "$@" ;;
  fire)    shift; cmd_fire "$@" ;;
  watch)   shift; cmd_watch "$@" ;;
  cleanup) shift; cmd_cleanup "$@" ;;
  *)       usage ;;
esac
