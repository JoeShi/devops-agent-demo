"""
WeCom Bot — AWS DevOps Agent SRE Chat
Long-lived WebSocket connection via WeCom aibot long-connection protocol.
Forwards @bot messages to DevOps Agent Chat API and streams replies back to
WeCom group chats.

Mirrors k8s/feishu-bot/app.py section-for-section. DevOps Agent EventStream
handling (lines ~70-120) is copy-adapted from the feishu-bot reference.
"""

import json
import logging
import os
import threading
import time
import uuid

import boto3
from websockets.sync.client import connect as ws_connect
from websockets.exceptions import ConnectionClosed

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("wecom-bot")

# ── Environment variables ───────────────────────────────────────────────────
WECOM_BOT_ID = os.environ["WECOM_BOT_ID"]
WECOM_BOT_SECRET = os.environ["WECOM_BOT_SECRET"]
AGENT_SPACE_ID = os.environ["DEVOPS_AGENT_SPACE_ID"]
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
WECOM_WS_URL = os.environ.get("WECOM_WS_URL", "wss://openws.work.weixin.qq.com")

# ── Protocol constants ─────────────────────────────────────────────────────
ACK_CONTENT = "收到，正在思考…"
# WeCom markdown has a 4096-byte server-side cap. Leave headroom for the
# enclosing frame and the "(i/N)" prefix we add to multi-chunk replies.
REPLY_MAX_BYTES = 3500
MAX_BACKOFF_SECONDS = 60

# ── AWS DevOps Agent client ────────────────────────────────────────────────
devops = boto3.client("devops-agent", region_name=AWS_REGION)

# ── Per-session execution ID cache (reset on restart) ──────────────────────
_sessions: dict[str, str] = {}
_lock = threading.Lock()


def get_or_create_execution(session_key: str) -> str:
    """Maintain one DevOps Agent executionId per WeCom conversation."""
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


# ── UTF-8 aware chunker for WeCom markdown 4096-byte server cap ────────────

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


# ── WeCom aibot long-connection frames ─────────────────────────────────────

def send_subscribe(ws) -> None:
    """Send the initial aibot_subscribe frame with bot_id + secret."""
    frame = {
        "cmd": "aibot_subscribe",
        "headers": {"req_id": uuid.uuid4().hex},
        "body": {"bot_id": WECOM_BOT_ID, "secret": WECOM_BOT_SECRET},
    }
    ws.send(json.dumps(frame))
    logger.info("Sent aibot_subscribe for bot_id=%s", WECOM_BOT_ID)


def send_ack(ws, req_id: str) -> None:
    """Reply to aibot_msg_callback with the ACK frame (same req_id)."""
    ack = {
        "cmd": "aibot_respond_msg",
        "headers": {"req_id": req_id},
        "body": {
            "msgtype": "markdown",
            "markdown": {"content": ACK_CONTENT},
        },
    }
    ws.send(json.dumps(ack, ensure_ascii=False))


def send_reply(ws, chatid: str | None, text: str) -> None:
    """Send the DevOps Agent reply back to WeCom, chunked if needed."""
    chunks = split_utf8_chunks(text, REPLY_MAX_BYTES)
    for i, chunk in enumerate(chunks, start=1):
        content = f"（{i}/{len(chunks)}）\n{chunk}" if len(chunks) > 1 else chunk
        frame = {
            "cmd": "aibot_send_msg",
            "headers": {"req_id": uuid.uuid4().hex},
            "body": {
                "chatid": chatid,
                "msgtype": "markdown",
                "markdown": {"content": content},
            },
        }
        try:
            ws.send(json.dumps(frame, ensure_ascii=False))
        except Exception:
            logger.exception("aibot_send_msg failed")
            return


def extract_session_and_text(body: dict) -> tuple[str, str]:
    """Pull chat session key + user text out of an aibot_msg_callback body.

    Prefer chatid so one WeCom group maps to one DevOps Agent execution;
    fall back to the sender userid for 1:1 DMs.
    """
    chat_id = body.get("chatid")
    user_id = (body.get("from") or {}).get("userid") or body.get("from_userid")
    session_key = chat_id or user_id or "default"
    if isinstance(body.get("text"), dict):
        text = body["text"].get("content", "")
    else:
        text = body.get("content", "")
    return session_key, (text or "").strip()


def handle_callback(ws, msg: dict) -> None:
    """Handle a single aibot_msg_callback frame: ack, then reply async."""
    body = msg.get("body", {}) or {}
    req_id = (msg.get("headers") or {}).get("req_id") or uuid.uuid4().hex

    # 1. Immediate ack so WeCom marks the @mention as handled.
    send_ack(ws, req_id)

    session_key, text = extract_session_and_text(body)
    if not text:
        logger.info("Empty text, ignoring session=%s", session_key)
        return

    logger.info("Received [%s]: %s", session_key, text[:200])

    # 2. Call DevOps Agent on a worker thread so the receive loop stays
    #    responsive to further frames (ack + ping + other chats).
    def _process():
        reply = ask_devops_agent(session_key, text)
        logger.info("Reply [%s]: %s", session_key, reply[:200])
        send_reply(ws, body.get("chatid"), reply)

    threading.Thread(target=_process, daemon=True).start()


# ── Main reconnect loop ────────────────────────────────────────────────────

def run_once() -> None:
    """One connect → subscribe → receive-loop cycle.

    Returns on graceful close or raises on error so the outer loop can
    back off and reconnect.
    """
    # WeCom's openws server rejects BOTH our JSON app-level ping and the
    # RFC 6455 ping frame with PROTOCOL_ERROR 1002 ("incorrect masking").
    # Disable library keepalive entirely; the subscribe session is long-lived
    # and the reconnect loop re-establishes the socket within ~1s on idle.
    with ws_connect(WECOM_WS_URL, ping_interval=None) as ws:
        logger.info("Connected to %s", WECOM_WS_URL)
        send_subscribe(ws)
        for raw in ws:
            try:
                msg = json.loads(raw)
            except (TypeError, ValueError):
                logger.debug("Non-JSON frame: %r", raw)
                continue
            if not isinstance(msg, dict):
                continue
            cmd = msg.get("cmd") or msg.get("type")
            if cmd == "aibot_msg_callback":
                handle_callback(ws, msg)
            else:
                logger.debug("Ignored frame cmd=%s", cmd)


def main() -> None:
    logger.info("Starting WeCom Bot WebSocket client …")
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
            logger.exception("WS error; reconnecting in %ds (attempt %d)",
                             delay, attempt)
            time.sleep(delay)


if __name__ == "__main__":
    main()
