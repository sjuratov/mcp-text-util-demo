import logging
import time

from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.utils import new_agent_text_message

from server.skills import route_request

logger = logging.getLogger("a2a.agent")


class TextUtilitiesAgent:
    """Pure-Python text utilities agent — no LLM calls."""

    async def invoke(self, user_text: str) -> str:
        return route_request(user_text)


class TextUtilitiesAgentExecutor(AgentExecutor):
    """A2A AgentExecutor wrapper for TextUtilitiesAgent."""

    def __init__(self) -> None:
        self.agent = TextUtilitiesAgent()

    async def execute(
        self,
        context: RequestContext,
        event_queue: EventQueue,
    ) -> None:
        user_text = ""
        if context.message and context.message.parts:
            user_text = context.message.parts[0].root.text

        logger.info(
            "Request received | task=%s context=%s input=%r",
            context.task_id,
            context.context_id,
            user_text[:100],
        )

        start = time.perf_counter()
        result = await self.agent.invoke(user_text)
        elapsed_ms = (time.perf_counter() - start) * 1000

        # Detect which skill was routed to from the result
        skill = _detect_skill(user_text, result)

        logger.info(
            "Request completed | task=%s skill=%s elapsed=%.1fms output=%r",
            context.task_id,
            skill,
            elapsed_ms,
            result[:100],
        )

        await event_queue.enqueue_event(new_agent_text_message(result))

    async def cancel(
        self,
        context: RequestContext,
        event_queue: EventQueue,
    ) -> None:
        raise Exception("cancel not supported")


def _detect_skill(user_text: str, result: str) -> str:
    """Best-effort detection of which skill was invoked."""
    if result.startswith("I can help"):
        return "help"
    lower = user_text.lower()
    if any(kw in lower for kw in ("uuid", "guid", "unique id")):
        return "generate_uuid"
    if any(kw in lower for kw in ("hash", "sha256")):
        return "hash_text"
    if "encode" in lower and "base64" in lower or lower.startswith("base64 encode"):
        return "base64_encode"
    if "decode" in lower and "base64" in lower or lower.startswith("base64 decode"):
        return "base64_decode"
    if any(kw in lower for kw in ("word count", "count words", "wc", "character count")):
        return "word_count"
    # Check by prefix patterns
    for prefix in ("hash:", "base64 encode:", "base64 decode:", "word count:"):
        if lower.startswith(prefix):
            return prefix.rstrip(":").replace(" ", "_")
    return "unknown"
