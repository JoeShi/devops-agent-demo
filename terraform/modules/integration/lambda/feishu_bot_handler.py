"""Lambda: Handle Feishu Bot event subscriptions via API Gateway."""

import hashlib
import hmac
import json
import logging
import os
from urllib.request import Request, urlopen
from urllib.error import URLError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

DEVOPS_AGENT_ENDPOINT = os.environ.get("DEVOPS_AGENT_ENDPOINT", "")
FEISHU_VERIFICATION_TOKEN = os.environ.get("FEISHU_VERIFICATION_TOKEN", "")
FEISHU_ENCRYPT_KEY = os.environ.get("FEISHU_ENCRYPT_KEY", "")


def handler(event, context):
    """Entry point for API Gateway POST events from Feishu Bot subscription."""
    body = event.get("body", "{}")
    if event.get("isBase64Encoded"):
        import base64
        body = base64.b64decode(body).decode()
    payload = json.loads(body)
    logger.info("Received payload: %s", json.dumps(payload))

    # Signature verification if encrypt key is configured
    if FEISHU_ENCRYPT_KEY and not _verify_signature(event, body):
        return _response(403, {"error": "invalid signature"})

    # URL verification challenge
    if "challenge" in payload:
        return _response(200, {"challenge": payload["challenge"]})

    # Handle event callback
    event_data = payload.get("event", {})
    message = event_data.get("message", {})
    content = json.loads(message.get("content", "{}")).get("text", "").strip()

    if not content:
        return _response(200, {"msg": "no message content"})

    # Forward query to DevOps Agent
    reply = _call_devops_agent(content)

    return _response(200, {
        "msg_type": "text",
        "content": {"text": reply},
    })


def _verify_signature(event, body):
    """Verify request signature from Feishu using HMAC-SHA256."""
    timestamp = (event.get("headers") or {}).get("x-lark-request-timestamp", "")
    nonce = (event.get("headers") or {}).get("x-lark-request-nonce", "")
    signature = (event.get("headers") or {}).get("x-lark-signature", "")

    raw = f"{timestamp}{nonce}{FEISHU_ENCRYPT_KEY}{body}"
    computed = hashlib.sha256(raw.encode()).hexdigest()
    return hmac.compare_digest(computed, signature)


def _call_devops_agent(query):
    """Forward user query to the DevOps Agent API endpoint."""
    if not DEVOPS_AGENT_ENDPOINT:
        return "DevOps Agent endpoint not configured."
    try:
        payload = json.dumps({"query": query}).encode()
        req = Request(DEVOPS_AGENT_ENDPOINT, data=payload, headers={"Content-Type": "application/json"})
        with urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read().decode())
            return result.get("answer", result.get("response", json.dumps(result)))
    except URLError as exc:
        logger.error("DevOps Agent call failed: %s", exc)
        return f"Failed to reach DevOps Agent: {exc}"


def _response(status_code, body):
    """Build API Gateway proxy response."""
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
