"""
MCP Server — AWS DevOps Agent SRE Chat
Exposes DevOps Agent Chat API as MCP tools for Amazon Quick Desktop integration.
Runs as a stateless Streamable HTTP server behind ALB.
"""

import logging
import os
import threading

import boto3
from mcp.server.fastmcp import FastMCP

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("mcp-server")

# ── Environment variables ───────────────────────────────────────────────────
AGENT_SPACE_ID = os.environ["DEVOPS_AGENT_SPACE_ID"]
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
BEARER_TOKEN = os.environ.get("MCP_BEARER_TOKEN", "")

# ── AWS DevOps Agent client ────────────────────────────────────────────────
devops = boto3.client("devops-agent", region_name=AWS_REGION)

# ── Per-session execution ID cache ─────────────────────────────────────────
_sessions: dict[str, str] = {}
_lock = threading.Lock()

# ── MCP Server ─────────────────────────────────────────────────────────────
mcp = FastMCP(
    "DevOps Agent SRE",
    json_response=True,
    host="0.0.0.0",
    port=8080,
)


def _get_or_create_execution(session_key: str) -> str:
    """Maintain one DevOps Agent executionId per conversation session."""
    with _lock:
        if session_key not in _sessions:
            resp = devops.create_chat(agentSpaceId=AGENT_SPACE_ID)
            _sessions[session_key] = resp["executionId"]
            logger.info("Created execution %s for session %s",
                        resp["executionId"], session_key)
        return _sessions[session_key]


def _call_agent(session_key: str, query: str) -> str:
    """Send a message to DevOps Agent and collect streamed response."""
    execution_id = _get_or_create_execution(session_key)
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
                delta = block.get("delta", {})
                text_delta = delta.get("textDelta", {})
                if "text" in text_delta:
                    blocks.setdefault(idx, []).append(text_delta["text"])
            elif "responseFailed" in event:
                err = event["responseFailed"]
                return f"Error: {err.get('errorMessage', 'unknown')}"
        if not blocks:
            return "(No response from DevOps Agent)"
        last_idx = max(blocks.keys())
        return "".join(blocks[last_idx])
    except Exception as e:
        logger.exception("DevOps Agent call failed")
        with _lock:
            _sessions.pop(session_key, None)
        return f"Call failed: {e}. Session reset, please retry."


@mcp.tool()
def sre_chat(question: str, session_id: str = "default") -> str:
    """Ask the AWS DevOps Agent an SRE question about your infrastructure.

    The agent can analyze metrics, logs, recent deployments, and provide
    root cause analysis for incidents. It has access to Grafana (Prometheus
    metrics + OpenSearch logs), CloudWatch, and GitHub repositories.

    Args:
        question: Your SRE question (e.g. "Why is API latency high?",
                  "What changed in the last deployment?",
                  "Show me error rate for outline-web pods")
        session_id: Optional session ID to maintain conversation context.
                    Use the same ID for follow-up questions.
    """
    logger.info("sre_chat [%s]: %s", session_id, question[:200])
    result = _call_agent(session_id, question)
    logger.info("sre_chat reply [%s]: %s", session_id, result[:200])
    return result


@mcp.tool()
def list_investigations() -> str:
    """List recent DevOps Agent investigations (incident analysis tasks).

    Returns a summary of recent investigations including their status,
    incident ID, and creation time.
    """
    try:
        resp = devops.list_backlog_tasks(
            agentSpaceId=AGENT_SPACE_ID,
            limit=10,
        )
        tasks = resp.get("backlogTasks", [])
        if not tasks:
            return "No investigations found."
        lines = []
        for t in tasks:
            lines.append(
                f"- [{t.get('status', '?')}] {t.get('title', 'Untitled')} "
                f"(ID: {t.get('taskId', '?')}, "
                f"Created: {t.get('createdAt', '?')})"
            )
        return "\n".join(lines)
    except Exception as e:
        return f"Failed to list investigations: {e}"


@mcp.tool()
def get_investigation(task_id: str) -> str:
    """Get details of a specific DevOps Agent investigation.

    Args:
        task_id: The investigation task ID (from list_investigations).
    """
    try:
        resp = devops.get_backlog_task(
            agentSpaceId=AGENT_SPACE_ID,
            taskId=task_id,
        )
        task = resp.get("backlogTask", resp)
        parts = [
            f"Title: {task.get('title', 'N/A')}",
            f"Status: {task.get('status', 'N/A')}",
            f"Created: {task.get('createdAt', 'N/A')}",
            f"Updated: {task.get('updatedAt', 'N/A')}",
        ]
        if task.get("rootCause"):
            parts.append(f"Root Cause: {task['rootCause']}")
        if task.get("summary"):
            parts.append(f"Summary: {task['summary']}")
        return "\n".join(parts)
    except Exception as e:
        return f"Failed to get investigation: {e}"


if __name__ == "__main__":
    import contextlib
    from starlette.applications import Starlette
    from starlette.responses import PlainTextResponse
    from starlette.routing import Route
    import uvicorn
    import threading
    from http.server import HTTPServer, BaseHTTPRequestHandler

    # Simple health check server on port 8081
    class HealthHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        def log_message(self, *args):
            pass

    def run_health():
        HTTPServer(("0.0.0.0", 8081), HealthHandler).serve_forever()

    threading.Thread(target=run_health, daemon=True).start()

    # Run FastMCP directly — it handles /mcp path correctly
    mcp.run(transport="streamable-http")
