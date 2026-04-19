#!/usr/bin/env bash
# capture-webhook-creds.sh — Capture the Agent Space Webhook URL/Secret
# generated in the AWS Console, then persist them to Secrets Manager and
# GitHub Actions secrets.
#
# Usage:
#   ./capture-webhook-creds.sh
#
# Prerequisites:
#   - aws CLI authenticated (same account as the Agent Space)
#   - gh CLI authenticated with repo:secrets scope on the tickets repo
#
# The script is interactive. Run it in a separate terminal BEFORE clicking
# "Generate URL and secret key" in the Console so you can paste immediately.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
SECRET_NAME="${SECRET_NAME:-/devops-agent/agent-space-webhook}"
TICKETS_REPO="${TICKETS_REPO:-JoeShi/devops-agent-demo-tickets}"

red()    { printf "\033[0;31m%s\033[0m\n" "$*"; }
green()  { printf "\033[0;32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[0;33m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }

command -v aws >/dev/null 2>&1 || { red "aws CLI not found"; exit 2; }
command -v gh  >/dev/null 2>&1 || { red "gh CLI not found"; exit 2; }
command -v jq  >/dev/null 2>&1 || { red "jq not found"; exit 2; }

bold "=== Capture Agent Space Webhook credentials ==="
echo
echo "Now go to the Console → Agent Space → Capabilities → Webhooks →"
echo "Agent Space Webhook → Add webhook → Step 3 → 'Generate URL and secret key'."
echo "Then copy the generated values and paste them below."
echo
echo "(AWS Console only shows the secret once; the Download .csv button is also"
echo " an option. This script will persist both values for future use.)"
echo

read -r -p "Webhook URL (https://event-ai.*.api.aws/webhook/generic/<UUID>): " WEBHOOK_URL
[[ "$WEBHOOK_URL" =~ ^https:// ]] || { red "URL must start with https://"; exit 1; }

read -r -s -p "Webhook Secret (input hidden): " WEBHOOK_SECRET
echo
[[ -n "$WEBHOOK_SECRET" ]] || { red "Secret cannot be empty"; exit 1; }

# ─── Persist to AWS Secrets Manager ─────────────────────────────────────────
bold "── [1/3] Storing in AWS Secrets Manager: $SECRET_NAME ──"

SECRET_JSON=$(jq -n \
  --arg url    "$WEBHOOK_URL" \
  --arg secret "$WEBHOOK_SECRET" \
  '{webhookUrl: $url, webhookSecret: $secret}')

if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  yellow "Secret already exists — updating value (new version will be created)"
  aws secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" \
    --secret-string "$SECRET_JSON" \
    --region "$AWS_REGION" >/dev/null
else
  aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "AWS DevOps Agent Space Webhook URL + HMAC secret" \
    --secret-string "$SECRET_JSON" \
    --region "$AWS_REGION" >/dev/null
fi
green "  ✅ Stored in Secrets Manager"

# ─── Configure GitHub secrets ───────────────────────────────────────────────
bold "── [2/3] Setting GitHub Actions secrets on $TICKETS_REPO ──"

if ! gh auth status >/dev/null 2>&1; then
  red "gh CLI not authenticated"; exit 2
fi

# Try to set via gh; fall back to manual instructions on 403
if echo "$WEBHOOK_URL" | gh secret set DEVOPS_AGENT_WEBHOOK_URL --repo "$TICKETS_REPO" 2>/dev/null \
   && echo "$WEBHOOK_SECRET" | gh secret set DEVOPS_AGENT_WEBHOOK_SECRET --repo "$TICKETS_REPO" 2>/dev/null; then
  green "  ✅ GitHub secrets set: DEVOPS_AGENT_WEBHOOK_URL, DEVOPS_AGENT_WEBHOOK_SECRET"
else
  yellow "  ⚠️  gh CLI failed (likely PAT lacks 'Secrets: Read and write')."
  echo
  echo "Please set these manually at:"
  echo "  https://github.com/${TICKETS_REPO}/settings/secrets/actions"
  echo
  echo "  Name: DEVOPS_AGENT_WEBHOOK_URL"
  echo "  Value: $WEBHOOK_URL"
  echo
  echo "  Name: DEVOPS_AGENT_WEBHOOK_SECRET"
  echo "  Value: (the secret you entered above)"
  echo
  read -r -p "Press ENTER after setting them manually..."
fi

# ─── Sanity check ──────────────────────────────────────────────────────────
bold "── [3/3] Sanity check ──"

STORED=$(aws secretsmanager get-secret-value \
           --secret-id "$SECRET_NAME" \
           --query SecretString --output text \
           --region "$AWS_REGION" | jq -r .webhookUrl)
if [[ "$STORED" == "$WEBHOOK_URL" ]]; then
  green "  ✅ Secrets Manager round-trip OK"
else
  red   "  ❌ Mismatch between stored and supplied URL"
fi

echo
bold "Done. You can now:"
echo "  - Run ./scripts/verify-pipeline.sh check to confirm the pipeline"
echo "  - Run ./scripts/verify-pipeline.sh fire to create a test incident"
