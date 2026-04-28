"""
WeCom Bot — AWS DevOps Agent SRE Chat

Uses the official ``wecom-aibot-python-sdk`` (WecomTeam/Tencent, PyPI v1.0.2+)
to maintain a long-lived WebSocket connection to the WeCom aibot long-connection
channel. Forwards @bot text messages to the AWS DevOps Agent Chat API and
streams replies back to WeCom group chats.

Mirrors k8s/feishu-bot/app.py in lifecycle shape and in DevOps Agent EventStream
parsing (``ask_devops_agent`` below is copy-adapted from feishu-bot app.py:57-89).
"""

import asyncio
import logging
import os

import boto3
from aibot import WSClient, WSClientOptions

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

# ── Protocol constants ─────────────────────────────────────────────────────
ACK_CONTENT = "收到，正在思考…"
# WeCom markdown has a 4096-byte server-side cap. Leave headroom for the
# enclosing frame and the "(i/N)" prefix we add to multi-chunk replies.
REPLY_MAX_BYTES = 3500

# ── AWS DevOps Agent client ────────────────────────────────────────────────
devops = boto3.client("devops-agent", region_name=AWS_REGION)

# ── Per-session execution ID cache (reset on restart) ──────────────────────
_sessions: dict[str, str] = {}
_sessions_lock = asyncio.Lock()


async def get_or_create_execution(session_key: str) -> str:
    """Maintain one DevOps Agent executionId per WeCom conversation."""
    async with _sessions_lock:
        if session_key not in _sessions:
            resp = await asyncio.to_thread(
                devops.create_chat, agentSpaceId=AGENT_SPACE_ID
            )
            _sessions[session_key] = resp["executionId"]
            logger.info("Created execution %s for session %s",
                        resp["executionId"], session_key)
        return _sessions[session_key]


async def ask_devops_agent(session_key: str, query: str) -> str:
    """Send a message and collect the streamed response."""
    execution_id = await get_or_create_execution(session_key)
    try:
        resp = await asyncio.to_thread(
            devops.send_message,
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
        async with _sessions_lock:
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


# ── Session + message helpers ──────────────────────────────────────────────

def extract_session_and_text(body: dict) -> tuple[str, str]:
    """Pull chat session key + user text out of a message callback body.

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


# ── Message handler ────────────────────────────────────────────────────────

async def _process_and_reply(ws_client: WSClient, frame: dict) -> None:
    """Run the DevOps Agent round-trip and send reply chunks."""
    body = frame.get("body") or {}
    session_key, text = extract_session_and_text(body)
    if not text:
        logger.info("Empty text, ignoring session=%s", session_key)
        return

    logger.info("Received [%s]: %s", session_key, text[:200])

    reply = await ask_devops_agent(session_key, text)
    logger.info("Reply [%s]: %s", session_key, reply[:200])

    chatid = body.get("chatid") or (body.get("from") or {}).get("userid")
    if not chatid:
        logger.warning("No chatid/userid in body, cannot send reply")
        return

    chunks = split_utf8_chunks(reply, REPLY_MAX_BYTES)
    for i, chunk in enumerate(chunks, start=1):
        content = f"（{i}/{len(chunks)}）\n{chunk}" if len(chunks) > 1 else chunk
        try:
            await ws_client.send_message(
                chatid,
                {"msgtype": "markdown", "markdown": {"content": content}},
            )
        except Exception:
            logger.exception("send_message failed (chunk %d/%d)", i, len(chunks))
            return


def register_handlers(ws_client: WSClient) -> None:
    """Wire SDK events to our async handlers."""

    @ws_client.on("message.text")
    async def on_text(frame: dict) -> None:
        # 1. Immediate ACK on the same req_id so WeCom marks the @mention as handled.
        try:
            await ws_client.reply(
                frame,
                {"msgtype": "markdown", "markdown": {"content": ACK_CONTENT}},
            )
        except Exception:
            logger.exception("ACK reply failed; continuing to process")

        # 2. Process on a background task so the handler returns fast and the
        #    SDK receive loop / heartbeat stay responsive.
        asyncio.create_task(_process_and_reply(ws_client, frame))


# ── Main ───────────────────────────────────────────────────────────────────

async def main() -> None:
    logger.info("Starting WeCom Bot via wecom-aibot-python-sdk …")
    ws_client = WSClient(
        WSClientOptions(
            bot_id=WECOM_BOT_ID,
            secret=WECOM_BOT_SECRET,
            max_reconnect_attempts=-1,  # infinite reconnect
        )
    )
    register_handlers(ws_client)
    await ws_client.connect()
    logger.info("WSClient connected; waiting for messages.")
    # Block until process is killed. The SDK owns reconnect internally.
    await asyncio.Event().wait()


if __name__ == "__main__":
    asyncio.run(main())
