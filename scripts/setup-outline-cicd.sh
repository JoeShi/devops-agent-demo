#!/usr/bin/env bash
set -euo pipefail

REPO="JoeShi/outline"
OUTLINE_DIR="$(cd "$(dirname "$0")/../../outline" && pwd)"
ROLE_ARN="arn:aws:iam::604179600882:role/outline-demo-eks-github-actions-deploy"

echo "==> Setting GitHub Actions secret AWS_DEPLOY_ROLE_ARN for ${REPO}"
gh secret set AWS_DEPLOY_ROLE_ARN -b "${ROLE_ARN}" --repo "${REPO}"

echo "==> Committing and pushing deploy-eks.yml"
cd "${OUTLINE_DIR}"
git checkout -b feat/eks-deploy-workflow 2>/dev/null || git checkout feat/eks-deploy-workflow
git add .github/workflows/deploy-eks.yml
git commit -m "ci: add GitHub Actions workflow for EKS deployment on merge to main"
git push -u origin feat/eks-deploy-workflow

echo ""
echo "Done! Create PR at:"
echo "  https://github.com/${REPO}/pull/new/feat/eks-deploy-workflow"
