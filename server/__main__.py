import logging
import os

from mcp.server.fastmcp import FastMCP

from server.skills import (
    base64_decode,
    base64_encode,
    generate_uuid,
    hash_text,
    word_count,
)


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


_transport = os.environ.get("MCP_TRANSPORT", "stdio")
# HOST and PORT are only used when MCP_TRANSPORT=sse (HTTP mode); ignored for stdio.
_host = os.environ.get("HOST", "0.0.0.0")
_port = int(os.environ.get("PORT", "8000"))
_json_response = os.environ.get("MCP_JSON_RESPONSE", "true").lower() in {
    "1",
    "true",
    "yes",
    "on",
}
_stateless_http = os.environ.get("MCP_STATELESS_HTTP", "false").lower() in {
    "1",
    "true",
    "yes",
    "on",
}

mcp = FastMCP(
    "Text Utilities",
    instructions=(
        "A lightweight text utilities MCP server providing UUID generation, "
        "SHA-256 hashing, Base64 encoding/decoding, and word/character counting. "
        "No LLM calls — pure Python, zero cost."
    ),
    host=_host,
    port=_port,
    # Streamable HTTP defaults to SSE-framed responses unless json_response is enabled.
    # Copilot Studio MCP ingestion is more reliable with plain JSON responses.
    json_response=_json_response,
    stateless_http=_stateless_http,
)

# Register each skill function as an MCP tool (docstrings become tool descriptions)
mcp.tool()(generate_uuid)
mcp.tool()(hash_text)
mcp.tool()(base64_encode)
mcp.tool()(base64_decode)
mcp.tool()(word_count)

if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    _configure_opentelemetry()

    mcp.run(transport=_transport)
