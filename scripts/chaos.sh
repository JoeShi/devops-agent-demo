#!/usr/bin/env bash
# Fault injection scripts for AWS DevOps Agent demo scenarios.
# Usage: ./chaos.sh <scenario> [--cleanup]
set -euo pipefail

NAMESPACE="${K8S_NAMESPACE:-outline}"
RDS_ENDPOINT="${RDS_ENDPOINT:-}"
REDIS_ENDPOINT="${REDIS_ENDPOINT:-}"

usage() {
  cat <<EOF
Usage: $0 <scenario> [--cleanup]

Scenarios:
  db-exhaust     Scenario 1: Exhaust RDS connection pool
  slow-deploy    Scenario 2: Deploy a bad image that causes high latency
  redis-failure  Scenario 3: Simulate Redis failure (delete pod / block traffic)
  export-oom     Scenario 6: Trigger export OOM via empty-title document

Options:
  --cleanup      Revert the injected fault
EOF
  exit 1
}

[[ $# -lt 1 ]] && usage
SCENARIO="$1"
CLEANUP="${2:-}"

# --- Scenario 1: DB connection pool exhaustion ---
db_exhaust() {
  if [[ "$CLEANUP" == "--cleanup" ]]; then
    echo "[cleanup] Deleting db-exhaust job..."
    kubectl delete job db-exhaust -n "$NAMESPACE" --ignore-not-found
    return
  fi
  echo "[inject] Creating job to exhaust DB connections..."
  kubectl apply -n "$NAMESPACE" -f - <<'JOB'
apiVersion: batch/v1
kind: Job
metadata:
  name: db-exhaust
  labels:
    app: chaos
    scenario: db-exhaust
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: pgbench
          image: postgres:16-alpine
          command: ["sh", "-c"]
          args:
            - |
              echo "Opening 100 idle connections to exhaust pool..."
              for i in $(seq 1 100); do
                psql "$DATABASE_URL" -c "SELECT pg_sleep(300);" &
              done
              wait
          envFrom:
            - secretRef:
                name: outline
JOB
  echo "[inject] db-exhaust job created. Monitor with:"
  echo "  kubectl logs -f job/db-exhaust -n $NAMESPACE"
}

# --- Scenario 2: Deploy bad image (simulates N+1 query / high latency) ---
slow_deploy() {
  if [[ "$CLEANUP" == "--cleanup" ]]; then
    echo "[cleanup] Rolling back outline-web deployment..."
    kubectl rollout undo deployment/outline-web -n "$NAMESPACE"
    kubectl rollout status deployment/outline-web -n "$NAMESPACE" --timeout=120s
    return
  fi
  echo "[inject] Patching outline-web with latency injection sidecar..."
  kubectl patch deployment outline-web -n "$NAMESPACE" --type=json -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/containers/-",
      "value": {
        "name": "latency-injector",
        "image": "alpine:3.20",
        "command": ["sh", "-c"],
        "args": ["apk add --no-cache iptables && iptables -A OUTPUT -p tcp --dport 5432 -j REJECT --reject-with tcp-reset; sleep 600"],
        "securityContext": {"capabilities": {"add": ["NET_ADMIN"]}}
      }
    }
  ]'
  echo "[inject] Sidecar injected. DB connections from web pods will be rejected."
  echo "  This simulates a deployment that breaks DB connectivity."
}

# --- Scenario 5: Redis failure ---
redis_failure() {
  if [[ "$CLEANUP" == "--cleanup" ]]; then
    echo "[cleanup] Removing Redis network policy..."
    kubectl delete networkpolicy block-redis -n "$NAMESPACE" --ignore-not-found
    return
  fi
  echo "[inject] Creating NetworkPolicy to block Redis traffic..."
  kubectl apply -n "$NAMESPACE" -f - <<'NP'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-redis
  labels:
    app: chaos
    scenario: redis-failure
spec:
  podSelector:
    matchLabels:
      app: outline
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - protocol: TCP
          port: 443
        - protocol: TCP
          port: 5432
        - protocol: TCP
          port: 53
        - protocol: UDP
          port: 53
    # Redis port 6379 is NOT listed — traffic blocked
NP
  echo "[inject] Redis traffic blocked via NetworkPolicy."
  echo "  WebSocket and caching will fail. Monitor with:"
  echo "  kubectl logs -l app=outline -n $NAMESPACE --tail=20"
}

# --- Scenario 6: Export OOM (empty-title document triggers memory leak) ---
export_oom() {
  local OUTLINE_URL="${OUTLINE_URL:-https://outline.devops-agent.xyz}"
  local OUTLINE_TOKEN="${OUTLINE_TOKEN:-}"

  if [[ -z "$OUTLINE_TOKEN" ]]; then
    echo "[error] OUTLINE_TOKEN env var required (Outline API token)"
    echo "  Get one from: ${OUTLINE_URL}/settings/api"
    exit 1
  fi

  if [[ "$CLEANUP" == "--cleanup" ]]; then
    echo "[cleanup] Restarting outline-worker to clear leaked memory..."
    kubectl rollout restart deployment/outline-worker -n "$NAMESPACE"
    kubectl rollout status deployment/outline-worker -n "$NAMESPACE" --timeout=120s
    echo "[cleanup] Done. Note: the empty-title document remains in Outline."
    echo "  Delete it manually from the UI if needed."
    return
  fi

  echo "[inject] Creating empty-title document in first collection..."

  # Get first collection
  COLLECTION_ID=$(curl -s -X POST "${OUTLINE_URL}/api/collections.list" \
    -H "Authorization: Bearer ${OUTLINE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{}' | python3 -c "import sys,json; data=json.load(sys.stdin); print(data['data'][0]['id'])" 2>/dev/null)

  if [[ -z "$COLLECTION_ID" ]]; then
    echo "[error] Failed to get collection ID. Check OUTLINE_TOKEN."
    exit 1
  fi

  echo "  Collection: $COLLECTION_ID"

  # Create a document with empty title (published so it appears in export)
  DOC_ID=$(curl -s -X POST "${OUTLINE_URL}/api/documents.create" \
    -H "Authorization: Bearer ${OUTLINE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"title\": \"\", \"text\": \"This document has no title.\", \"collectionId\": \"${COLLECTION_ID}\", \"publish\": true}" \
    | python3 -c "import sys,json; data=json.load(sys.stdin); print(data['data']['id'])" 2>/dev/null)

  if [[ -z "$DOC_ID" ]]; then
    echo "[error] Failed to create document. API response unexpected."
    exit 1
  fi

  echo "  Created empty-title document: $DOC_ID"
  echo ""
  echo "[inject] Now trigger the bug by exporting the collection:"
  echo "  1. Open ${OUTLINE_URL}"
  echo "  2. Go to the collection → click '⋯' → 'Export'"
  echo "  3. Worker will crash within ~30 seconds"
  echo ""
  echo "  Or trigger via API:"
  echo "  curl -X POST ${OUTLINE_URL}/api/collections.export \\"
  echo "    -H 'Authorization: Bearer ${OUTLINE_TOKEN}' \\"
  echo "    -H 'Content-Type: application/json' \\"
  echo "    -d '{\"id\": \"${COLLECTION_ID}\"}'"
}

case "$SCENARIO" in
  db-exhaust)    db_exhaust ;;
  slow-deploy)   slow_deploy ;;
  redis-failure) redis_failure ;;
  export-oom)    export_oom ;;
  *)             usage ;;
esac
