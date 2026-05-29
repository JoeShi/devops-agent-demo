"""
Feishu Bot SRE — AWS DevOps Agent Chat + Alert Cards
WebSocket long-lived connection for chat.
HTTP :8080 for receiving alert card pushes (from Lambda/SNS).
"""

import json
import logging
import os
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler

import boto3
import lark_oapi as lark
from lark_oapi.api.im.v1 import (
    CreateMessageRequest,
    CreateMessageRequestBody,
    CreateMessageReactionRequest,
    CreateMessageReactionRequestBody,
    Emoji,
    ReplyMessageRequest,
    ReplyMessageRequestBody,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("feishu-bot-sre")

# ── Config ──────────────────────────────────────────────────────────────────
FEISHU_APP_ID = os.environ["FEISHU_APP_ID"]
FEISHU_APP_SECRET = os.environ["FEISHU_APP_SECRET"]
AGENT_SPACE_ID = os.environ["DEVOPS_AGENT_SPACE_ID"]
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
ALERT_CHAT_ID = os.environ.get("FEISHU_CHAT_ID", "")

# ── AWS DevOps Agent ────────────────────────────────────────────────────────
devops = boto3.client("devops-agent", region_name=AWS_REGION)
_sessions: dict[str, str] = {}
_lock = threading.Lock()


def get_or_create_execution(session_key: str) -> str:
    with _lock:
        if session_key not in _sessions:
            resp = devops.create_chat(agentSpaceId=AGENT_SPACE_ID)
            _sessions[session_key] = resp["executionId"]
            logger.info("New execution %s for %s", resp["executionId"], session_key)
        return _sessions[session_key]


def ask_devops_agent(session_key: str, query: str) -> str:
    execution_id = get_or_create_execution(session_key)
    try:
        resp = devops.send_message(
            agentSpaceId=AGENT_SPACE_ID,
            executionId=execution_id,
            content=query,
        )
        blocks: dict[int, list[str]] = {}
        for event in resp.get("events", []):
            if "contentBlockDelta" in event:
                block = event["contentBlockDelta"]
                idx = block.get("contentBlockIndex", 0)
                text = block.get("delta", {}).get("textDelta", {}).get("text")
                if text:
                    blocks.setdefault(idx, []).append(text)
            elif "responseFailed" in event:
                err = event["responseFailed"]
                return f"DevOps Agent 错误：{err.get('errorMessage', 'unknown')}"
        if not blocks:
            return "（DevOps Agent 未返回内容）"
        return "".join(blocks[max(blocks.keys())])
    except Exception:
        logger.exception("DevOps Agent call failed")
        with _lock:
            _sessions.pop(session_key, None)
        return "调用失败，已重置会话，请重试。"


# ── Chat: plain text reply ──────────────────────────────────────────────────

def send_text_reply(client: lark.Client, message_id: str, text: str) -> None:
    """Reply as Feishu interactive card with markdown rendering."""
    import re
    title = "DevOps Agent"
    m = re.match(r'^#{1,3}\s+(.+)', text.strip())
    if m:
        title = m.group(1).strip()
        text = text.strip().split("\n", 1)[-1].strip()

    card = json.dumps({
        "header": {
            "template": "blue",
            "title": {"tag": "plain_text", "content": title},
        },
        "elements": [{"tag": "markdown", "content": text}],
    })
    resp = client.im.v1.message.reply(
        ReplyMessageRequest.builder()
        .message_id(message_id)
        .request_body(
            ReplyMessageRequestBody.builder()
            .msg_type("interactive")
            .content(card)
            .build()
        )
        .build()
    )
    if not resp.success():
        logger.error("Reply failed: %s %s", resp.code, resp.msg)


def add_reaction(client: lark.Client, message_id: str) -> None:
    client.im.v1.message_reaction.create(
        CreateMessageReactionRequest.builder()
        .message_id(message_id)
        .request_body(
            CreateMessageReactionRequestBody.builder()
            .reaction_type(Emoji.builder().emoji_type("OnIt").build())
            .build()
        )
        .build()
    )


# ── Alert: send card to group ───────────────────────────────────────────────

def send_alert_card(client: lark.Client, card: dict, chat_id: str = "") -> None:
    target = chat_id or ALERT_CHAT_ID
    if not target:
        logger.warning("No FEISHU_CHAT_ID, skip alert card")
        return
    resp = client.im.v1.message.create(
        CreateMessageRequest.builder()
        .receive_id_type("chat_id")
        .request_body(
            CreateMessageRequestBody.builder()
            .receive_id(target)
            .msg_type("interactive")
            .content(json.dumps(card))
            .build()
        )
        .build()
    )
    if not resp.success():
        logger.error("Card send failed: %s %s", resp.code, resp.msg)
    else:
        logger.info("Alert card sent to %s", target)


# ── WebSocket handler ───────────────────────────────────────────────────────

def build_message_handler(client: lark.Client):
    def on_message(data: lark.im.v1.P2ImMessageReceiveV1) -> None:
        msg = data.event.message
        if msg.message_type != "text":
            return
        text = json.loads(msg.content).get("text", "").strip()
        if text.startswith("@"):
            text = text.split(" ", 1)[-1].strip()
        if not text:
            return

        add_reaction(client, msg.message_id)
        session_key = msg.chat_id or data.event.sender.sender_id.open_id
        logger.info("Chat [%s]: %s", session_key, text[:200])

        def _process():
            reply = ask_devops_agent(session_key, text)
            logger.info("Reply [%s]: %s", session_key, reply[:200])
            send_text_reply(client, msg.message_id, reply)

        threading.Thread(target=_process, daemon=True).start()

    return on_message


# ── HTTP server for alert webhook ───────────────────────────────────────────

_client: lark.Client = None


class AlertHandler(BaseHTTPRequestHandler):
    """POST /alert with {"card": {...}, "chat_id": "optional"}"""

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        card = body.get("card")
        if card and _client:
            send_alert_card(_client, card, body.get("chat_id", ""))
            self._ok({"sent": True})
        else:
            self._ok({"error": "missing card"}, 400)

    def do_GET(self):
        self._ok({"status": "ok"})

    def _ok(self, data, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def log_message(self, *_):
        pass


# ── Main ────────────────────────────────────────────────────────────────────

def main() -> None:
    global _client
    _client = (
        lark.Client.builder()
        .app_id(FEISHU_APP_ID)
        .app_secret(FEISHU_APP_SECRET)
        .log_level(lark.LogLevel.INFO)
        .build()
    )

    handler = (
        lark.EventDispatcherHandler.builder("", "")
        .register_p2_im_message_receive_v1(build_message_handler(_client))
        .build()
    )

    # Alert HTTP server (background)
    threading.Thread(
        target=lambda: HTTPServer(("0.0.0.0", 8080), AlertHandler).serve_forever(),
        daemon=True,
    ).start()
    logger.info("Alert server on :8080")

    # WebSocket (blocking)
    ws = lark.ws.Client(FEISHU_APP_ID, FEISHU_APP_SECRET,
                        event_handler=handler, log_level=lark.LogLevel.INFO)
    logger.info("Starting WebSocket …")
    ws.start()


if __name__ == "__main__":
    main()
