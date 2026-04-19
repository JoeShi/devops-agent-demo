"""Lambda: Forward DevOps Agent investigation events to GitHub Issue comments.

EventBridge source: aws.aidevops
Handled detail-types:
  - Investigation Created
  - Investigation In Progress
  - Investigation Completed
  - Investigation Failed
  - Investigation Timed Out
  - Investigation Cancelled
  - Investigation Pending Triage

Each event writes a comment on the GitHub Issue that triggered the investigation.

How the task → issue mapping works:
  The Agent Space Webhook receives an incident payload with
  incidentId = "<repo>#<number>" (sent by the GitHub Actions workflow).
  DevOps Agent persists this as reference.referenceId on the backlog task.
  On each event we call get-backlog-task(task_id) and parse reference.referenceId
  back into (repo, number). No SSM parameter is needed — mapping is stateless.
"""

import json
import logging
import os
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

GITHUB_TOKEN_SECRET = os.environ["GITHUB_TOKEN_SECRET"]
GITHUB_TICKETS_REPO = os.environ["GITHUB_TICKETS_REPO"]   # e.g. JoeShi/devops-agent-demo-tickets
DEVOPS_AGENT_SPACE_ID = os.environ["DEVOPS_AGENT_SPACE_ID"]
# Operator Web URL template. Placeholders:
#   {space_id}  – Agent Space ID (appears twice in the real URL)
#   {task_id}   – backlog task ID (aka investigation ID)
# Default points to the real operator web app (not the AWS Console).
OPERATOR_WEB_URL_TEMPLATE = os.environ.get(
    "OPERATOR_WEB_URL_TEMPLATE",
    "https://{space_id}.aidevops.global.app.aws/{space_id}/investigation/{task_id}",
)
AWS_REGION = os.environ.get("DEVOPS_AGENT_REGION", os.environ.get("AWS_REGION", "us-east-1"))

_secrets_client = None
_devops_client = None
_github_token = None


def _secrets():
    global _secrets_client
    if _secrets_client is None:
        _secrets_client = boto3.client("secretsmanager")
    return _secrets_client


def _devops():
    global _devops_client
    if _devops_client is None:
        _devops_client = boto3.client("devops-agent", region_name=AWS_REGION)
    return _devops_client


def _get_github_token():
    global _github_token
    if _github_token is None:
        resp = _secrets().get_secret_value(SecretId=GITHUB_TOKEN_SECRET)
        _github_token = resp["SecretString"]
    return _github_token


# ── Task → Issue resolution (stateless via get-backlog-task) ────────────────

def _resolve_issue_from_task(task_id):
    """Return (repo, issue_number) by reading reference.referenceId from the task.

    The GitHub Actions workflow sends incidentId = "<repo>#<number>" in the
    webhook payload, which DevOps Agent stores as reference.referenceId.
    """
    try:
        resp = _devops().get_backlog_task(
            agentSpaceId=DEVOPS_AGENT_SPACE_ID,
            taskId=task_id,
        )
    except Exception as exc:
        logger.error("get_backlog_task failed for %s: %s", task_id, exc)
        return None, None

    reference = resp.get("task", {}).get("reference", {}) or {}
    ref_id = reference.get("referenceId", "")
    if not ref_id or "#" not in ref_id:
        logger.warning(
            "Task %s has no usable referenceId (got %r); skipping", task_id, ref_id
        )
        return None, None

    try:
        repo, number = ref_id.rsplit("#", 1)
        return repo, int(number)
    except (ValueError, AttributeError):
        logger.error("Cannot parse referenceId %r from task %s", ref_id, task_id)
        return None, None


# ── DevOps Agent journal ─────────────────────────────────────────────────────

def _get_investigation_summary(execution_id):
    """Fetch the investigation_summary_md journal record, return markdown string."""
    if not execution_id:
        return None
    try:
        paginator = _devops().get_paginator("list_journal_records")
        pages = paginator.paginate(
            agentSpaceId=DEVOPS_AGENT_SPACE_ID,
            executionId=execution_id,
            recordType="investigation_summary_md",
        )
        for page in pages:
            for record in page.get("records", []):
                content = record.get("content", {})
                # content is a document type — may be dict or raw string
                if isinstance(content, dict):
                    return content.get("text") or content.get("markdown") or json.dumps(content)
                return str(content)
    except Exception as exc:
        logger.error("Failed to fetch journal records: %s", exc)
    return None


# ── GitHub API ───────────────────────────────────────────────────────────────

def _post_comment(repo, issue_number, body):
    token = _get_github_token()
    url = f"https://api.github.com/repos/{repo}/issues/{issue_number}/comments"
    payload = json.dumps({"body": body}).encode()
    req = Request(
        url,
        data=payload,
        headers={
            "Authorization": f"token {token}",
            "Accept": "application/vnd.github.v3+json",
            "Content-Type": "application/json",
        },
    )
    try:
        with urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read().decode())
            logger.info("Posted comment #%s on %s#%s", result.get("id"), repo, issue_number)
            return result.get("html_url", "")
    except HTTPError as exc:
        logger.error("GitHub API HTTP error %s: %s", exc.code, exc.read().decode())
    except URLError as exc:
        logger.error("GitHub API error: %s", exc)
    return ""


# ── Comment builders ─────────────────────────────────────────────────────────

def _investigation_url(task_id):
    return OPERATOR_WEB_URL_TEMPLATE.format(
        space_id=DEVOPS_AGENT_SPACE_ID,
        task_id=task_id,
    )


def _build_comment(detail_type, task_id, execution_id, status, priority, summary_record_id):
    inv_url = _investigation_url(task_id)
    eye_link = f"👁 [在 Operator Web 中查看调查]({inv_url})"

    if detail_type == "Investigation Created":
        return (
            "## DevOps Agent 调查已创建\n\n"
            f"- **状态**: 排队中 (Pending)\n"
            f"- **优先级**: {priority}\n"
            f"- **Task ID**: `{task_id}`\n\n"
            f"{eye_link}\n\n"
            "调查正在排队，请稍候..."
        )

    if detail_type == "Investigation Pending Triage":
        return (
            "## DevOps Agent 调查待分类\n\n"
            f"- **状态**: Pending Triage\n"
            f"- **优先级**: {priority}\n\n"
            f"{eye_link}\n\n"
            "调查正在等待人工分类后开始。"
        )

    if detail_type == "Investigation In Progress":
        return (
            "## DevOps Agent 调查进行中\n\n"
            f"- **状态**: In Progress\n"
            f"- **优先级**: {priority}\n"
            f"- **Task ID**: `{task_id}`\n\n"
            f"{eye_link}"
        )

    if detail_type == "Investigation Completed":
        summary = _get_investigation_summary(execution_id)
        body = (
            "## ✅ DevOps Agent 调查完成\n\n"
            f"- **状态**: Completed\n"
            f"- **优先级**: {priority}\n\n"
            f"{eye_link}\n\n"
        )
        if summary:
            body += "---\n\n### 根因摘要\n\n" + summary
        else:
            body += "_根因摘要正在生成中，请前往 Operator Web 查看详情。_"
        return body

    if detail_type == "Investigation Failed":
        return (
            "## ❌ DevOps Agent 调查失败\n\n"
            f"- **状态**: Failed\n"
            f"- **优先级**: {priority}\n\n"
            f"{eye_link}\n\n"
            "调查遇到错误，未能完成。"
        )

    if detail_type == "Investigation Timed Out":
        return (
            "## ⏱ DevOps Agent 调查超时\n\n"
            f"- **状态**: Timed Out\n\n"
            f"{eye_link}\n\n"
            "调查超出最大允许时长。"
        )

    if detail_type == "Investigation Cancelled":
        return (
            "## ⛔ DevOps Agent 调查已取消\n\n"
            f"- **状态**: Cancelled\n\n"
            f"{eye_link}"
        )

    # fallback
    return (
        f"## DevOps Agent 状态更新: {detail_type}\n\n"
        f"- **状态**: {status}\n"
        f"- **优先级**: {priority}\n\n"
        f"{eye_link}"
    )


# ── Entry point ──────────────────────────────────────────────────────────────

def handler(event, context):
    logger.info("Event: %s", json.dumps(event))

    detail_type = event.get("detail-type", "")
    detail = event.get("detail", {})
    metadata = detail.get("metadata", {})
    data = detail.get("data", {})

    # Only handle investigation events
    if not detail_type.startswith("Investigation"):
        logger.info("Ignoring non-investigation event: %s", detail_type)
        return {"statusCode": 200, "body": "ignored"}

    task_id = metadata.get("task_id", "")
    execution_id = metadata.get("execution_id", "")
    status = data.get("status", "")
    priority = data.get("priority", "UNKNOWN")
    summary_record_id = data.get("summary_record_id", "")

    if not task_id:
        logger.error("No task_id in event metadata")
        return {"statusCode": 400, "body": "missing task_id"}

    # Resolve task → GitHub issue via reference.referenceId (stateless)
    repo, issue_number = _resolve_issue_from_task(task_id)
    if not repo or not issue_number:
        logger.warning(
            "Cannot resolve GitHub issue for task_id=%s, skipping comment", task_id
        )
        return {"statusCode": 200, "body": "no issue mapping"}

    comment_body = _build_comment(
        detail_type, task_id, execution_id, status, priority, summary_record_id
    )

    comment_url = _post_comment(repo, issue_number, comment_body)
    logger.info("Comment posted: %s", comment_url)

    return {"statusCode": 200, "body": json.dumps({"comment_url": comment_url})}
