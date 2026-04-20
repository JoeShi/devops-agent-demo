"""Lambda: Forward alerts to Feishu (via Bot identity) and create GitHub Issues."""

import json
import logging
import os
from urllib.request import Request, urlopen
from urllib.error import URLError

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

FEISHU_BOT_SECRET = os.environ.get("FEISHU_BOT_SECRET", "")
FEISHU_CHAT_ID = os.environ.get("FEISHU_CHAT_ID", "")
GITHUB_TOKEN_SECRET = os.environ.get("GITHUB_TOKEN_SECRET", "")
GITHUB_REPO = os.environ.get("GITHUB_REPO", "")

# Container-level caches
_secrets_client = None
_feishu_creds = None
_github_token = None
_tenant_token = None


def _get_secrets_client():
    global _secrets_client
    if _secrets_client is None:
        _secrets_client = boto3.client("secretsmanager")
    return _secrets_client


def _get_feishu_creds():
    """Fetch Feishu App ID/Secret from Secrets Manager, cached per container."""
    global _feishu_creds
    if _feishu_creds is None and FEISHU_BOT_SECRET:
        resp = _get_secrets_client().get_secret_value(SecretId=FEISHU_BOT_SECRET)
        _feishu_creds = json.loads(resp["SecretString"])
    return _feishu_creds or {}


def _get_github_token():
    global _github_token
    if _github_token is None and GITHUB_TOKEN_SECRET:
        resp = _get_secrets_client().get_secret_value(SecretId=GITHUB_TOKEN_SECRET)
        _github_token = resp["SecretString"]
    return _github_token or ""


def _get_tenant_access_token():
    """Get tenant_access_token from Feishu API (refreshed each invocation)."""
    global _tenant_token
    creds = _get_feishu_creds()
    if not creds:
        return ""
    payload = json.dumps({
        "app_id": creds["FEISHU_APP_ID"],
        "app_secret": creds["FEISHU_APP_SECRET"],
    }).encode()
    req = Request(
        "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read().decode())
    if result.get("code") != 0:
        logger.error("Failed to get tenant_access_token: %s", result)
        return ""
    _tenant_token = result["tenant_access_token"]
    return _tenant_token


# ── Entry point ─────────────────────────────────────────────────────────────

def handler(event, context):
    logger.info("Received event: %s", json.dumps(event))

    # SNS invocation (from Alertmanager SNS receiver)
    if "Records" in event and event["Records"][0].get("EventSource") == "aws:sns":
        message = event["Records"][0]["Sns"]["Message"]
        # Alertmanager SNS may send JSON or plain text depending on config
        try:
            body = json.loads(message)
        except (json.JSONDecodeError, TypeError):
            # Plain text message from Alertmanager default template
            # Parse what we can from the SNS attributes and message text
            attrs = event["Records"][0]["Sns"].get("MessageAttributes", {})
            subject = event["Records"][0]["Sns"].get("Subject", "")
            body = _parse_plaintext_alert(message, subject, attrs)
        return _handle_alertmanager(body)

    return _handle_eventbridge(event)


def _parse_plaintext_alert(message, subject, attrs):
    """Parse Alertmanager's default plain-text SNS message into alert structure."""
    import re
    from datetime import datetime, timezone

    # Extract alertname from Labels section
    alertname = "PrometheusAlert"
    match = re.search(r"alertname\s*=\s*(\S+)", message)
    if match:
        alertname = match.group(1)
    elif subject:
        alertname = subject.strip()

    # Extract severity
    severity = "critical"
    match = re.search(r"severity\s*=\s*(\S+)", message)
    if match:
        severity = match.group(1)

    # Extract summary/description from Annotations section
    summary = alertname
    match = re.search(r"summary\s*=\s*(.+?)(?:\n|$)", message)
    if match:
        summary = match.group(1).strip()

    description = summary
    match = re.search(r"description\s*=\s*(.+?)(?:\n|$)", message)
    if match:
        description = match.group(1).strip()

    # Extract namespace
    namespace = ""
    match = re.search(r"namespace\s*=\s*(\S+)", message)
    if match:
        namespace = match.group(1)

    # Build Grafana dashboard URL
    dashboard_url = "https://grafana.devops-agent.xyz/d/outline-app-overview/outline-application-overview"

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    return {
        "status": "firing",
        "commonLabels": {"alertname": alertname},
        "alerts": [{
            "status": "firing",
            "labels": {"alertname": alertname, "severity": severity, "namespace": namespace},
            "annotations": {"summary": summary, "description": description},
            "startsAt": now,
            "generatorURL": dashboard_url,
            "dashboardURL": dashboard_url,
        }]
    }


def _handle_alertmanager(body):
    alerts = body.get("alerts", [])
    status = body.get("status", "unknown")
    title = body.get("commonLabels", {}).get("alertname", "Grafana Alert")

    for alert in alerts:
        severity = alert.get("labels", {}).get("severity", "warning")
        summary = alert.get("annotations", {}).get("summary",
                    alert.get("annotations", {}).get("description", ""))
        dashboard_url = alert.get("dashboardURL", alert.get("generatorURL", ""))
        alert_status = alert.get("status", status)

        issue_url = ""
        if severity in ("critical", "high", "error"):
            issue_url = _create_or_update_github_issue(title, severity, summary,
                                                       alert_status, dashboard_url)

        card = _build_card(title, severity, alert.get("startsAt", ""),
                           "grafana", summary, alert_status, dashboard_url, issue_url)
        _send_feishu_card(card)

    return {"statusCode": 200, "body": json.dumps({"message": f"Processed {len(alerts)} alerts"})}


def _handle_eventbridge(event):
    source = event.get("source", "unknown")
    detail = event.get("detail", {})
    detail_type = event.get("detail-type", "Unknown Event")
    severity = detail.get("severity", "info")
    summary = detail.get("summary", detail.get("message", "No summary"))
    status = detail.get("status", "triggered")
    timestamp = event.get("time", "")
    console_url = detail.get("console_url", detail.get("dashboard_url", ""))

    issue_url = ""
    if severity in ("critical", "high", "error") or "incident" in detail_type.lower():
        issue_url = _create_or_update_github_issue(detail_type, severity, summary,
                                                   status, console_url)

    card = _build_card(detail_type, severity, timestamp, source,
                       summary, status, console_url, issue_url)
    _send_feishu_card(card)

    return {"statusCode": 200, "body": "ok"}


# ── Feishu (Bot identity) ──────────────────────────────────────────────────

def _build_card(title, severity, timestamp, source, summary, status, action_url, issue_url=""):
    color = {"critical": "red", "high": "red", "error": "orange",
             "warning": "yellow"}.get(severity, "blue")
    buttons = [
        {
            "tag": "button",
            "text": {"tag": "plain_text", "content": "查看监控"},
            "url": action_url or "https://grafana.devops-agent.xyz",
            "type": "primary",
        },
    ]
    if issue_url:
        buttons.append({
            "tag": "button",
            "text": {"tag": "plain_text", "content": "查看工单"},
            "url": issue_url,
            "type": "danger",
        })
    return {
        "header": {
            "title": {"tag": "plain_text", "content": f"[{severity.upper()}] {title}"},
            "template": color,
        },
        "elements": [
            {
                "tag": "div",
                "fields": [
                    {"is_short": True, "text": {"tag": "lark_md", "content": f"**Timestamp**\n{timestamp}"}},
                    {"is_short": True, "text": {"tag": "lark_md", "content": f"**Source**\n{source}"}},
                    {"is_short": True, "text": {"tag": "lark_md", "content": f"**Status**\n{status}"}},
                    {"is_short": False, "text": {"tag": "lark_md", "content": f"**Summary**\n{summary}"}},
                ],
            },
            {"tag": "action", "actions": buttons},
        ],
    }


def _send_feishu_card(card):
    """Send an interactive card to the Feishu group as the Bot."""
    if not FEISHU_CHAT_ID:
        logger.warning("FEISHU_CHAT_ID not set, skipping")
        return
    token = _get_tenant_access_token()
    if not token:
        logger.error("No tenant_access_token, cannot send Feishu message")
        return
    payload = json.dumps({
        "receive_id": FEISHU_CHAT_ID,
        "msg_type": "interactive",
        "content": json.dumps(card),
    }).encode()
    req = Request(
        "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
    )
    try:
        with urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read().decode())
            if result.get("code") != 0:
                logger.error("Feishu send failed: %s", result)
            else:
                logger.info("Feishu message sent: %s", result.get("data", {}).get("message_id"))
    except URLError as exc:
        logger.error("Failed to send Feishu message: %s", exc)


# ── GitHub Issues ───────────────────────────────────────────────────────────

def _create_or_update_github_issue(title, severity, summary, status, url):
    if not _get_github_token() or not GITHUB_REPO:
        logger.warning("GitHub token or repo not set, skipping")
        return ""

    token = _get_github_token()
    api_url = f"https://api.github.com/repos/{GITHUB_REPO}/issues"
    body = f"**Severity:** {severity}\n**Status:** {status}\n**Summary:** {summary}\n\n[View Details]({url})"
    payload = json.dumps({"title": f"[{severity.upper()}] {title}", "body": body,
                          "labels": ["incident", severity]}).encode()
    search_url = (f"https://api.github.com/search/issues?q=repo:{GITHUB_REPO}"
                  f"+is:issue+is:open+in:title+{title.replace(' ', '+')}")
    headers = {"Authorization": f"token {token}", "Accept": "application/vnd.github.v3+json"}

    try:
        search_req = Request(search_url, headers=headers)
        with urlopen(search_req, timeout=10) as resp:
            results = json.loads(resp.read().decode())

        if results.get("total_count", 0) > 0:
            issue = results["items"][0]
            issue_number = issue["number"]
            comment_url = f"https://api.github.com/repos/{GITHUB_REPO}/issues/{issue_number}/comments"
            comment_payload = json.dumps({"body": f"**Update — Status:** {status}\n\n{summary}"}).encode()
            req = Request(comment_url, data=comment_payload,
                          headers={**headers, "Content-Type": "application/json"})
            with urlopen(req, timeout=10) as resp:
                logger.info("Updated GitHub issue #%s", issue_number)
            return issue.get("html_url", "")

        req = Request(api_url, data=payload,
                      headers={**headers, "Content-Type": "application/json"})
        with urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read().decode())
            logger.info("Created GitHub issue #%s", result.get("number"))
            return result.get("html_url", "")
    except URLError as exc:
        logger.error("GitHub API error: %s", exc)
        return ""
