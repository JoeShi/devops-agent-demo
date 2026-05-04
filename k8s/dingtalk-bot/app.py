"""
DingTalk Bot — AWS DevOps Agent SRE Chat
Long-lived WebSocket connection via DingTalk Stream protocol.
Forwards @bot messages to DevOps Agent Chat API and streams replies back to
DingTalk group chats.

Mirrors k8s/wecom-bot/app.py section-for-section. DevOps Agent EventStream
handling is copy-adapted from the wecom-bot reference.

DingTalk Stream protocol:
  1. POST /v1.0/gateway/connections/open → get WebSocket endpoint + ticket
  2. Connect to wss://... with ticket as query param
  3. Receive SYSTEM/CALLBACK/PING events
  4. Reply to CALLBACK events with HTTP POST to callback response URL
  5. Send proactive messages via OpenAPI /v1.0/robot/groupMessages/send
"""

import json
import logging
import os
import re
import threading
import time
import urllib.error
import urllib.request

import boto3
from websockets.sync.client import connect as ws_connect
from websockets.exceptions import ConnectionClosed

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("dingtalk-bot")

# ── Environment variables ───────────────────────────────────────────────────
DINGTALK_APP_KEY = os.environ["DINGTALK_APP_KEY"]
DINGTALK_APP_SECRET = os.environ["DINGTALK_APP_SECRET"]
AGENT_SPACE_ID = os.environ["DEVOPS_AGENT_SPACE_ID"]
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

# ── Protocol constants ─────────────────────────────────────────────────────
ACK_TEXT = "收到，正在思考…"
# DingTalk markdown has a ~4096-byte server-side cap for group messages.
REPLY_MAX_BYTES = 3500
MAX_BACKOFF_SECONDS = 60
GATEWAY_URL = "https://api.dingtalk.com/v1.0/gateway/connections/open"

# ── AWS DevOps Agent client ────────────────────────────────────────────────
devops = boto3.client("devops-agent", region_name=AWS_REGION)

# ── Per-session execution ID cache (reset on restart) ──────────────────────
_sessions: dict[str, str] = {}
_lock = threading.Lock()

# ── DingTalk access token cache ────────────────────────────────────────────
_access_token: str = ""
_token_expires: float = 0
_token_lock = threading.Lock()


def _get_access_token() -> str:
    """Get DingTalk access_token with caching (thread-safe)."""
    global _access_token, _token_expires
    with _token_lock:
        if _access_token and time.time() < _token_expires:
            return _access_token

        url = "https://api.dingtalk.com/v1.0/oauth2/accessToken"
        data = json.dumps({
            "appKey": DINGTALK_APP_KEY,
            "appSecret": DINGTALK_APP_SECRET,
        }).encode("utf-8")
        req = urllib.request.Request(
            url, data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                result = json.loads(resp.read().decode("utf-8"))
                _access_token = result.get("accessToken", "")
                expire = result.get("expireIn", 7200)
                _token_expires = time.time() + expire - 300
                logger.info("DingTalk access_token refreshed, expires in %ds", expire)
                return _access_token
        except Exception as e:
            logger.error("Failed to get DingTalk access_token: %s", e)
            return ""


def get_or_create_execution(session_key: str) -> str:
    """Maintain one DevOps Agent executionId per DingTalk conversation."""
    with _lock:
        if session_key not in _sessions:
            resp = devops.create_chat(agentSpaceId=AGENT_SPACE_ID)
            _sessions[session_key] = resp["executionId"]
            logger.info("Created execution %s for session %s",
                        resp["executionId"], session_key)
        return _sessions[session_key]


def ask_devops_agent(session_key: str, query: str) -> str:
    """Send a message and collect the streamed response."""
    execution_id = get_or_create_execution(session_key)
    try:
        resp = devops.send_message(
            agentSpaceId=AGENT_SPACE_ID,
            executionId=execution_id,
            content=query,
        )
        # Collect text from the EventStream, grouped by content block index
        blocks: dict[int, list[str]] = {}
        for event in resp.get("events", []):
            if "contentBlockDelta" in event:
                block = event["contentBlockDelta"]
                idx = block.get("contentBlockIndex", 0)
                delta = block.get("delta", {})
                text_delta = delta.get("textDelta", {})
                if "text" in text_delta:
                    blocks.setdefault(idx, []).append(text_delta["text"])
            elif "responseFailed" in event:
                err = event["responseFailed"]
                logger.error("Agent response failed: %s", err.get("errorMessage"))
                return f"DevOps Agent 返回错误：{err.get('errorMessage', 'unknown')}"
        if not blocks:
            return "（DevOps Agent 未返回内容）"
        # Use the last content block (highest index) as the final response
        last_idx = max(blocks.keys())
        return "".join(blocks[last_idx])
    except Exception:
        logger.exception("DevOps Agent call failed")
        # Evict session so next call creates a fresh execution
        with _lock:
            _sessions.pop(session_key, None)
        return "调用 DevOps Agent 失败，已重置会话，请重试。"


# ── UTF-8 aware chunker for DingTalk markdown byte cap ─────────────────────

def split_utf8_chunks(text: str, max_bytes: int = REPLY_MAX_BYTES) -> list[str]:
    """Split text into pieces each ≤ max_bytes in UTF-8.

    Prefer line boundaries so code / Mermaid blocks stay readable; fall back
    to byte-wise hard cut on UTF-8 char boundaries for oversized single lines.
    """
    encoded = text.encode("utf-8")
    if len(encoded) <= max_bytes:
        return [text]

    chunks: list[str] = []
    buf: list[str] = []
    buf_bytes = 0
    for line in text.split("\n"):
        line_bytes = len(line.encode("utf-8")) + 1  # +1 for newline
        if line_bytes > max_bytes:
            if buf:
                chunks.append("\n".join(buf))
                buf, buf_bytes = [], 0
            enc = line.encode("utf-8")
            for start in range(0, len(enc), max_bytes):
                piece = enc[start:start + max_bytes].decode(
                    "utf-8", errors="ignore"
                )
                if piece:
                    chunks.append(piece)
            continue
        if buf_bytes + line_bytes > max_bytes:
            chunks.append("\n".join(buf))
            buf, buf_bytes = [line], line_bytes
        else:
            buf.append(line)
            buf_bytes += line_bytes
    if buf:
        chunks.append("\n".join(buf))
    return chunks


# ── Markdown preprocessing for DingTalk ────────────────────────────────────

def _preprocess_for_dingtalk(text: str) -> str:
    """Preprocess Markdown for DingTalk limitations.

    DingTalk markdown does NOT support:
    - Tables (| syntax) → convert to plain text list
    - Code blocks render as-is (keep them, still readable)
    Everything else (headings, bold, lists, links, quotes) is natively supported.
    """
    lines = text.split("\n")
    result: list[str] = []
    in_code_block = False
    in_table = False
    table_headers: list[str] = []

    for line in lines:
        if line.strip().startswith("```"):
            in_code_block = not in_code_block
            result.append(line)
            continue

        if in_code_block:
            result.append(line)
            continue

        stripped = line.strip()
        if "|" in stripped and stripped.startswith("|") and stripped.endswith("|"):
            cells = [c.strip() for c in stripped.strip("|").split("|")]
            if all(re.match(r"^:?-+:?$", c) for c in cells):
                continue
            if not in_table:
                in_table = True
                table_headers = cells
                result.append("  ".join(f"**{c}**" for c in cells))
            else:
                if table_headers and len(cells) == len(table_headers):
                    result.append("  ".join(
                        f"{table_headers[i]}: {cells[i]}" for i in range(len(cells))
                    ))
                else:
                    result.append("  ".join(cells))
            continue

        if in_table:
            in_table = False
            table_headers = []

        result.append(line)

    return "\n".join(result)


def _extract_title(text: str) -> str:
    """Extract first heading as notification bar title."""
    for line in text.split("\n"):
        m = re.match(r"^#{1,6}\s+(.+)", line.strip())
        if m:
            return m.group(1)[:20]
    return "DevOps Agent"


# ── DingTalk Stream protocol ───────────────────────────────────────────────

def _open_connection() -> dict:
    """Call DingTalk gateway to get a WebSocket endpoint + ticket.

    Returns: {"endpoint": "wss://...", "ticket": "..."}
    """
    data = json.dumps({
        "clientId": DINGTALK_APP_KEY,
        "clientSecret": DINGTALK_APP_SECRET,
        "subscriptions": [
            {"type": "EVENT", "topic": "/v1.0/im/bot/messages/get"},
        ],
    }).encode("utf-8")
    req = urllib.request.Request(
        GATEWAY_URL, data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        result = json.loads(resp.read().decode("utf-8"))
        endpoint = result.get("endpoint", "")
        ticket = result.get("ticket", "")
        if not endpoint or not ticket:
            raise ValueError(f"Gateway returned incomplete response: {result}")
        logger.info("Gateway connection opened: endpoint=%s", endpoint[:80])
        return {"endpoint": endpoint, "ticket": ticket}


def _send_group_message(open_conversation_id: str, text: str) -> bool:
    """Send a markdown message to a DingTalk group chat via OpenAPI."""
    token = _get_access_token()
    if not token:
        logger.error("Cannot send group message: no access_token")
        return False

    processed = _preprocess_for_dingtalk(text)
    title = _extract_title(processed)

    url = "https://api.dingtalk.com/v1.0/robot/groupMessages/send"
    payload = {
        "robotCode": DINGTALK_APP_KEY,
        "openConversationId": open_conversation_id,
        "msgKey": "sampleMarkdown",
        "msgParam": json.dumps({
            "title": title,
            "text": processed,
        }, ensure_ascii=False),
    }

    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        url, data=data,
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "x-acs-dingtalk-access-token": token,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            json.loads(resp.read().decode("utf-8"))
            logger.info("Group message sent: openConversationId=%s",
                        open_conversation_id)
            return True
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        logger.error("Group message failed: status=%s, body=%s", e.code, body[:500])
        return False
    except Exception as e:
        logger.error("Group message error: %s", e)
        return False


def _send_single_message(user_id: str, text: str) -> bool:
    """Send a markdown message to a single user via OpenAPI (1:1 DM)."""
    token = _get_access_token()
    if not token:
        logger.error("Cannot send single message: no access_token")
        return False

    processed = _preprocess_for_dingtalk(text)
    title = _extract_title(processed)

    url = "https://api.dingtalk.com/v1.0/robot/oToMessages/batchSend"
    payload = {
        "robotCode": DINGTALK_APP_KEY,
        "userIds": [user_id],
        "msgKey": "sampleMarkdown",
        "msgParam": json.dumps({
            "title": title,
            "text": processed,
        }, ensure_ascii=False),
    }

    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        url, data=data,
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "x-acs-dingtalk-access-token": token,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            json.loads(resp.read().decode("utf-8"))
            logger.info("Single message sent: userId=%s", user_id)
            return True
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        logger.error("Single message failed: status=%s, body=%s", e.code, body[:500])
        return False
    except Exception as e:
        logger.error("Single message error: %s", e)
        return False


def send_reply(conversation_id: str | None, sender_id: str,
               conversation_type: str, text: str) -> None:
    """Send the DevOps Agent reply back to DingTalk, chunked if needed."""
    chunks = split_utf8_chunks(text, REPLY_MAX_BYTES)
    for i, chunk in enumerate(chunks, start=1):
        content = f"（{i}/{len(chunks)}）\n{chunk}" if len(chunks) > 1 else chunk
        if conversation_type == "2" and conversation_id:
            _send_group_message(conversation_id, content)
        else:
            _send_single_message(sender_id, content)


def extract_session_and_text(data: dict) -> tuple[str, str, str, str]:
    """Extract session key, user text, conversation info from callback data.

    Returns: (session_key, text, conversation_id, conversation_type)
    """
    conversation_id = data.get("conversationId", "")
    conversation_type = data.get("conversationType", "1")
    sender_id = data.get("senderId", data.get("senderStaffId", ""))

    # Group chat → use conversationId as session; DM → use senderId
    session_key = conversation_id if conversation_type == "2" else sender_id
    session_key = session_key or "default"

    text_obj = data.get("text", {})
    if isinstance(text_obj, dict):
        text = text_obj.get("content", "")
    else:
        text = str(text_obj)

    return session_key, (text or "").strip(), conversation_id, conversation_type


def handle_callback(data: dict) -> None:
    """Handle a bot message callback: call DevOps Agent and reply."""
    session_key, text, conversation_id, conversation_type = \
        extract_session_and_text(data)
    sender_id = data.get("senderId", data.get("senderStaffId", ""))

    if not text:
        logger.info("Empty text, ignoring session=%s", session_key)
        return

    logger.info("Received [%s]: %s", session_key, text[:200])

    def _process():
        reply = ask_devops_agent(session_key, text)
        logger.info("Reply [%s]: %s", session_key, reply[:200])
        send_reply(conversation_id, sender_id, conversation_type, reply)

    threading.Thread(target=_process, daemon=True).start()


# ── Main reconnect loop ────────────────────────────────────────────────────

def run_once() -> None:
    """One connect → subscribe → receive-loop cycle.

    DingTalk Stream protocol:
    1. POST /v1.0/gateway/connections/open → get wss endpoint + ticket
    2. Connect to wss endpoint with ticket
    3. Receive JSON frames: SYSTEM (connected), CALLBACK (bot message), PING
    4. Reply PING with PONG to keep alive
    """
    conn = _open_connection()
    ws_url = f"{conn['endpoint']}?ticket={conn['ticket']}"

    with ws_connect(ws_url, ping_interval=None) as ws:
        logger.info("Connected to DingTalk Stream")

        for raw in ws:
            try:
                msg = json.loads(raw)
            except (TypeError, ValueError):
                logger.debug("Non-JSON frame: %r", raw)
                continue

            if not isinstance(msg, dict):
                continue

            msg_type = msg.get("type", "")
            headers = msg.get("headers", {})
            data_str = msg.get("data", "")

            # SYSTEM event — connection established
            if msg_type == "SYSTEM":
                topic = headers.get("topic", "")
                logger.info("System event: topic=%s", topic)
                continue

            # PING — respond with PONG to keep connection alive
            if msg_type == "PING":
                pong = json.dumps({
                    "code": 200,
                    "headers": headers,
                    "message": "OK",
                    "data": data_str,
                })
                ws.send(pong)
                continue

            # CALLBACK — bot message received
            if msg_type == "CALLBACK":
                # Acknowledge the callback immediately
                ack = json.dumps({
                    "code": 200,
                    "headers": headers,
                    "message": "OK",
                    "data": "",
                })
                ws.send(ack)

                # Parse the callback data
                try:
                    if isinstance(data_str, str):
                        data = json.loads(data_str)
                    else:
                        data = data_str
                except (json.JSONDecodeError, TypeError):
                    logger.warning("Failed to parse callback data: %s",
                                   str(data_str)[:200])
                    continue

                handle_callback(data)
                continue

            logger.debug("Ignored frame type=%s", msg_type)


def main() -> None:
    logger.info("Starting DingTalk Bot Stream client …")
    attempt = 0
    while True:
        try:
            run_once()
            # Graceful close — reset backoff and reconnect immediately.
            attempt = 0
        except ConnectionClosed as exc:
            delay = min(2 ** attempt, MAX_BACKOFF_SECONDS)
            attempt += 1
            logger.warning("WS closed (%s); reconnecting in %ds (attempt %d)",
                           exc, delay, attempt)
            time.sleep(delay)
        except Exception:
            delay = min(2 ** attempt, MAX_BACKOFF_SECONDS)
            attempt += 1
            logger.exception("Error; reconnecting in %ds (attempt %d)",
                             delay, attempt)
            time.sleep(delay)


if __name__ == "__main__":
    main()
