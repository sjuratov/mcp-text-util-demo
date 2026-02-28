import os
from typing import Any

import uvicorn

from a2a.server.apps import A2AStarletteApplication
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.tasks import InMemoryTaskStore
from a2a.types import AgentCapabilities, AgentCard, AgentSkill

from server.agent import TextUtilitiesAgentExecutor


def _configure_opentelemetry() -> None:
    """Configure Azure Monitor OpenTelemetry if connection string is available."""
    conn_str = os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING")
    if not conn_str:
        return

    from azure.monitor.opentelemetry import configure_azure_monitor

    configure_azure_monitor(
        connection_string=conn_str,
        enable_live_metrics=True,
    )


def build_agent_card(base_url: str = "http://localhost:8000") -> AgentCard:
    skills = [
        AgentSkill(
            id="generate_uuid",
            name="Generate UUID",
            description="Generates a new UUID v4",
            tags=["uuid", "guid", "generate"],
            examples=["generate a uuid", "give me a unique id"],
        ),
        AgentSkill(
            id="hash_text",
            name="Hash Text (SHA-256)",
            description="Computes SHA-256 hash of the provided text",
            tags=["hash", "sha256", "checksum"],
            examples=["hash: hello world", "sha256 of my password"],
        ),
        AgentSkill(
            id="base64_encode",
            name="Base64 Encode",
            description="Base64-encodes the provided text",
            tags=["base64", "encode"],
            examples=["base64 encode: hello", "encode to base64: secret"],
        ),
        AgentSkill(
            id="base64_decode",
            name="Base64 Decode",
            description="Base64-decodes the provided text",
            tags=["base64", "decode"],
            examples=["base64 decode: aGVsbG8=", "decode base64: c2VjcmV0"],
        ),
        AgentSkill(
            id="word_count",
            name="Word & Character Count",
            description="Counts words and characters in the provided text",
            tags=["word count", "character count", "wc"],
            examples=["word count: the quick brown fox", "count words in this sentence"],
        ),
    ]

    return AgentCard(
        name="Text Utilities Agent",
        description=(
            "A lightweight text utilities agent providing UUID generation, "
            "SHA-256 hashing, Base64 encoding/decoding, and word/character counting. "
            "No LLM calls — pure Python, zero cost."
        ),
        url=base_url.rstrip("/"),
        version="0.1.0",
        defaultInputModes=["text"],
        defaultOutputModes=["text"],
        capabilities=AgentCapabilities(streaming=True),
        skills=skills,
    )


def _get_allowed_origins() -> list[str]:
    origins = os.environ.get(
        "CORS_ALLOW_ORIGINS",
        "https://copilotstudio.microsoft.com,https://copilotstudio.preview.microsoft.com",
    )
    return [origin.strip() for origin in origins.split(",") if origin.strip()]


class _SimpleCorsMiddleware:
    def __init__(self, app: Any, allowed_origins: list[str]) -> None:
        self.app = app
        self.allowed_origins = set(allowed_origins)

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return

        headers = {k.decode("latin1"): v.decode("latin1") for k, v in scope.get("headers", [])}
        origin = headers.get("origin")
        allow_origin = origin if origin in self.allowed_origins else None
        method = scope.get("method", "").upper()

        if method == "OPTIONS" and allow_origin:
            await send(
                {
                    "type": "http.response.start",
                    "status": 204,
                    "headers": [
                        (b"access-control-allow-origin", allow_origin.encode("latin1")),
                        (b"access-control-allow-methods", b"GET,POST,OPTIONS"),
                        (b"access-control-allow-headers", b"Authorization,Content-Type"),
                        (b"access-control-allow-credentials", b"true"),
                        (b"vary", b"Origin"),
                    ],
                }
            )
            await send({"type": "http.response.body", "body": b""})
            return

        async def send_wrapper(message: dict[str, Any]) -> None:
            if message.get("type") == "http.response.start" and allow_origin:
                response_headers = list(message.get("headers", []))
                response_headers.extend(
                    [
                        (b"access-control-allow-origin", allow_origin.encode("latin1")),
                        (b"access-control-allow-methods", b"GET,POST,OPTIONS"),
                        (b"access-control-allow-headers", b"Authorization,Content-Type"),
                        (b"access-control-allow-credentials", b"true"),
                        (b"vary", b"Origin"),
                    ]
                )
                message["headers"] = response_headers
            await send(message)

        await self.app(scope, receive, send_wrapper)


if __name__ == "__main__":
    import logging

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    _configure_opentelemetry()

    host = "0.0.0.0"
    port = 8000
    public_base_url = os.environ.get("AGENT_PUBLIC_BASE_URL", "http://localhost:8000")

    agent_card = build_agent_card(public_base_url)

    request_handler = DefaultRequestHandler(
        agent_executor=TextUtilitiesAgentExecutor(),
        task_store=InMemoryTaskStore(),
    )

    server = A2AStarletteApplication(
        agent_card=agent_card,
        http_handler=request_handler,
    )

    app = _SimpleCorsMiddleware(server.build(), _get_allowed_origins())

    uvicorn.run(app, host=host, port=port)
