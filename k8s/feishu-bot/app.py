"""
Feishu Bot — AWS DevOps Agent SRE Chat
Long-lived WebSocket connection via lark-oapi SDK.
Forwards messages to DevOps Agent Chat API and streams replies back to Feishu.
"""

import json
import logging
import os
import re
import threading

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
logger = logging.getLogger("feishu-bot")

# ── Environment variables ───────────────────────────────────────────────────
FEISHU_APP_ID = os.environ["FEISHU_APP_ID"]
FEISHU_APP_SECRET = os.environ["FEISHU_APP_SECRET"]
AGENT_SPACE_ID = os.environ["DEVOPS_AGENT_SPACE_ID"]
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

# ── AWS DevOps Agent client ────────────────────────────────────────────────
devops = boto3.client("devops-agent", region_name=AWS_REGION)

# ── Per-session execution ID cache (reset on restart) ──────────────────────
_sessions: dict[str, str] = {}
_lock = threading.Lock()


def get_or_create_execution(session_key: str) -> str:
    """Maintain one DevOps Agent executionId per Feishu conversation."""
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


# ── Markdown → Feishu Post conversion ──────────────────────────────────────

def _inline_parse(text: str) -> list[dict]:
    """Parse inline markdown (bold, code, links) into Feishu post elements."""
    elements: list[dict] = []
    pattern = re.compile(
        r'\*\*(.+?)\*\*'              # **bold**
        r'|`([^`]+)`'                 # `inline code`
        r'|\[([^\]]+)\]\(([^)]+)\)'   # [text](url)
    )
    last_end = 0
    for m in pattern.finditer(text):
        if m.start() > last_end:
            elements.append({"tag": "text", "text": text[last_end:m.start()]})
        if m.group(1) is not None:
            elements.append({"tag": "text", "text": m.group(1), "style": ["bold"]})
        elif m.group(2) is not None:
            elements.append({"tag": "text", "text": f"「{m.group(2)}」", "style": ["bold"]})
        elif m.group(3) is not None:
            elements.append({"tag": "a", "text": m.group(3), "href": m.group(4)})
        last_end = m.end()
    if last_end < len(text):
        elements.append({"tag": "text", "text": text[last_end:]})
    if not elements:
        elements.append({"tag": "text", "text": text})
    return elements


def markdown_to_post(md: str) -> dict:
    """Convert markdown to Feishu post content.

    Handles: headings, code blocks, bullet/numbered lists, bold, inline code,
    links, horizontal rules, and plain paragraphs.
    """
    lines = md.split("\n")
    title = ""
    content: list[list[dict]] = []
    i = 0
    while i < len(lines):
        line = lines[i]

        # Heading → first one becomes title, rest become bold paragraphs
        heading_match = re.match(r'^(#{1,3})\s+(.+)', line)
        if heading_match:
            heading_text = heading_match.group(2).strip()
            if not title:
                title = heading_text
            else:
                content.append([{"tag": "text", "text": heading_text, "style": ["bold"]}])
            i += 1
            continue

        # Fenced code block
        if line.strip().startswith("```"):
            lang = line.strip().removeprefix("```").strip()
            code_lines: list[str] = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                code_lines.append(lines[i])
                i += 1
            i += 1  # skip closing ```
            code_text = "\n".join(code_lines)
            content.append([{"tag": "text", "text": f"```{lang}\n{code_text}\n```"}])
            continue

        # Markdown table → render as code block to preserve alignment
        if re.match(r'^\s*\|.+\|', line):
            table_lines: list[str] = []
            while i < len(lines) and re.match(r'^\s*\|.+\|', lines[i]):
                # Skip separator rows (|---|---|)
                if not re.match(r'^\s*\|[\s\-:|]+\|$', lines[i]):
                    table_lines.append(lines[i].strip())
                i += 1
            if table_lines:
                content.append([{"tag": "text", "text": "\n".join(table_lines)}])
            continue

        # Bullet list item
        bullet_match = re.match(r'^(\s*)[*\-+]\s+(.+)', line)
        if bullet_match:
            indent = len(bullet_match.group(1))
            prefix = "  " * (indent // 2) + "• "
            content.append(_inline_parse(prefix + bullet_match.group(2)))
            i += 1
            continue

        # Numbered list item
        num_match = re.match(r'^(\s*)\d+[.)]\s+(.+)', line)
        if num_match:
            content.append(_inline_parse(line))
            i += 1
            continue

        # Horizontal rule
        if re.match(r'^-{3,}$|^\*{3,}$|^_{3,}$', line.strip()):
            content.append([{"tag": "text", "text": "─" * 20}])
            i += 1
            continue

        # Empty line → skip
        if not line.strip():
            i += 1
            continue

        # Plain paragraph with inline formatting
        content.append(_inline_parse(line))
        i += 1

    if not title:
        title = "DevOps Agent"

    return {"zh_cn": {"title": title, "content": content}}


def add_reaction(client: lark.Client, message_id: str,
                 emoji_type: str = "OnIt") -> None:
    """Add an emoji reaction to acknowledge the message."""
    request = (
        CreateMessageReactionRequest.builder()
        .message_id(message_id)
        .request_body(
            CreateMessageReactionRequestBody.builder()
            .reaction_type(Emoji.builder().emoji_type(emoji_type).build())
            .build()
        )
        .build()
    )
    response = client.im.v1.message_reaction.create(request)
    if not response.success():
        logger.error("Failed to add reaction: code=%s msg=%s",
                     response.code, response.msg)


def _parse_md_table(lines: list[str]) -> dict | None:
    """Convert markdown table lines into a Feishu card table element."""
    # Need at least header + separator + 1 data row
    if len(lines) < 3:
        return None
    # Parse header
    headers = [c.strip() for c in lines[0].strip().strip("|").split("|")]
    # Skip separator (line 1)
    rows = []
    for row_line in lines[2:]:
        cells = [c.strip() for c in row_line.strip().strip("|").split("|")]
        rows.append(cells)
    if not headers:
        return None

    columns = []
    for i, h in enumerate(headers):
        columns.append({
            "name": f"col_{i}",
            "display_name": h,
            "data_type": "text",
            "width": "auto",
        })

    table_rows = []
    for row in rows:
        row_data = {}
        for i, cell in enumerate(row):
            if i < len(headers):
                row_data[f"col_{i}"] = cell
        table_rows.append(row_data)

    return {
        "tag": "table",
        "page_size": len(table_rows),
        "row_height": "low",
        "header_style": {"text_align": "left", "bold": True},
        "columns": columns,
        "rows": table_rows,
    }


def _split_md_into_elements(text: str) -> list[dict]:
    """Split markdown into card elements: markdown blocks + native tables.

    Feishu limits the number of table components per card, so we cap at
    MAX_TABLES and fall back to plain text for any extras.
    """
    MAX_TABLES = 3
    lines = text.split("\n")
    elements: list[dict] = []
    buf: list[str] = []
    table_count = 0
    i = 0

    def flush_buf():
        content = "\n".join(buf).strip()
        if content:
            elements.append({"tag": "markdown", "content": content})
        buf.clear()

    while i < len(lines):
        line = lines[i]
        # Detect table: line starts with | and next line is separator
        if (re.match(r'^\s*\|.+\|', line)
                and i + 1 < len(lines)
                and re.match(r'^\s*\|[\s\-:|]+\|$', lines[i + 1])):
            flush_buf()
            table_lines = []
            while i < len(lines) and re.match(r'^\s*\|.+\|', lines[i]):
                table_lines.append(lines[i])
                i += 1
            if table_count < MAX_TABLES:
                table_elem = _parse_md_table(table_lines)
                if table_elem:
                    elements.append(table_elem)
                    table_count += 1
                    continue
            # Over limit or parse failed: render as markdown text
            elements.append({"tag": "markdown", "content": "\n".join(table_lines)})
        else:
            buf.append(line)
            i += 1

    flush_buf()
    return elements


def send_feishu_reply(client: lark.Client, message_id: str, text: str) -> None:
    """Reply to a specific message as a Feishu interactive card."""
    # Extract first heading as card title
    title = "DevOps Agent"
    title_match = re.match(r'^#{1,3}\s+(.+)', text.strip())
    if title_match:
        title = title_match.group(1).strip()
        text = text.strip().split("\n", 1)[-1].strip()

    elements = _split_md_into_elements(text)
    if not elements:
        elements = [{"tag": "markdown", "content": text}]

    card = {
        "header": {
            "template": "blue",
            "title": {"tag": "plain_text", "content": title},
        },
        "elements": elements,
    }
    request = (
        ReplyMessageRequest.builder()
        .message_id(message_id)
        .request_body(
            ReplyMessageRequestBody.builder()
            .msg_type("interactive")
            .content(json.dumps(card))
            .build()
        )
        .build()
    )
    response = client.im.v1.message.reply(request)
    if not response.success():
        logger.error("Failed to reply: code=%s msg=%s",
                     response.code, response.msg)


def build_message_handler(client: lark.Client):
    """Factory: returns a message event handler bound to the Feishu client."""

    def on_message(data: lark.im.v1.P2ImMessageReceiveV1) -> None:
        event = data.event
        message = event.message

        if message.message_type != "text":
            return

        text = json.loads(message.content).get("text", "").strip()
        # Strip @bot mention prefix
        if text.startswith("@"):
            text = text.split(" ", 1)[-1].strip()
        if not text:
            return

        # ACK immediately with a reaction emoji
        add_reaction(client, message.message_id)

        session_key = message.chat_id or event.sender.sender_id.open_id
        logger.info("Received [%s]: %s", session_key, text[:200])

        def _process():
            reply = ask_devops_agent(session_key, text)
            logger.info("Reply [%s]: %s", session_key, reply[:200])
            send_feishu_reply(client, message.message_id, reply)

        threading.Thread(target=_process, daemon=True).start()

    return on_message


def main() -> None:
    client = (
        lark.Client.builder()
        .app_id(FEISHU_APP_ID)
        .app_secret(FEISHU_APP_SECRET)
        .log_level(lark.LogLevel.INFO)
        .build()
    )

    event_handler = (
        lark.EventDispatcherHandler.builder("", "")
        .register_p2_im_message_receive_v1(build_message_handler(client))
        .build()
    )

    ws_client = lark.ws.Client(
        FEISHU_APP_ID,
        FEISHU_APP_SECRET,
        event_handler=event_handler,
        log_level=lark.LogLevel.INFO,
    )
    logger.info("Starting Feishu Bot WebSocket client …")
    ws_client.start()


if __name__ == "__main__":
    main()
