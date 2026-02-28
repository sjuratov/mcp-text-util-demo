"""Interactive CLI client for the A2A Text Utilities Agent."""

import asyncio
import os
import sys
from typing import Any
from uuid import uuid4

from a2a.client import A2ACardResolver, A2AClient
from a2a.types import (
    MessageSendParams,
    SendMessageRequest,
    SendStreamingMessageRequest,
)
from dotenv import load_dotenv

import httpx


def _load_env() -> None:
    """Load .env from client/ directory, then from project root."""
    client_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(client_dir)
    load_dotenv(os.path.join(client_dir, ".env"))
    load_dotenv(os.path.join(project_root, ".env"))


def _intent_detection_enabled() -> bool:
    return bool(os.environ.get("AZURE_OPENAI_ENDPOINT"))


def _get_auth_headers(base_url: str) -> dict[str, str]:
    """Acquire a bearer token for Azure EasyAuth if app IDs are configured."""
    if "localhost" in base_url or "127.0.0.1" in base_url:
        return {}
    api_app_id = os.environ.get("A2A_AGENT_API_APP_ID") or os.environ.get("A2A_AGENT_CLIENT_ID")
    if not api_app_id:
        return {}
    try:
        from azure.identity import InteractiveBrowserCredential

        client_app_id = os.environ.get("A2A_AGENT_CLIENT_APP_ID")
        tenant_id = os.environ.get("AZURE_TENANT_ID")
        credential = InteractiveBrowserCredential(client_id=client_app_id, tenant_id=tenant_id)
        token = credential.get_token(f"api://{api_app_id}/access_as_user")
        return {"Authorization": f"Bearer {token.token}"}
    except Exception as e:
        print(f"  Warning: Could not acquire auth token: {e}")
        return {}


async def main(base_url: str | None = None) -> None:
    _load_env()
    if base_url is None:
        base_url = os.environ.get("A2A_AGENT_URL", "http://localhost:8000")

    intent_enabled = _intent_detection_enabled()
    if intent_enabled:
        from client.intent import detect_intent, rewrite_for_agent

    auth_headers = _get_auth_headers(base_url)
    if auth_headers:
        api_app_id = os.environ.get("A2A_AGENT_API_APP_ID") or os.environ.get("A2A_AGENT_CLIENT_ID")
        print(f"Auth:         Bearer token for api://{api_app_id}")
    else:
        print("Auth:         None (set A2A_AGENT_API_APP_ID in .env to enable)")

    async with httpx.AsyncClient(headers=auth_headers) as httpx_client:
        # Discover agent card
        resolver = A2ACardResolver(httpx_client=httpx_client, base_url=base_url)

        try:
            agent_card = await resolver.get_agent_card()
        except Exception as e:
            print(f"Error: Could not connect to agent at {base_url}: {e}")
            sys.exit(1)

        # Override the agent card URL to match the actual endpoint we connected to
        agent_card.url = base_url

        print(f"Connected to: {agent_card.name}")
        print(f"Description:  {agent_card.description}")
        print(f"Skills:       {', '.join(s.name for s in agent_card.skills)}")
        if intent_enabled:
            print(f"Intent:       Azure OpenAI ({os.environ.get('AZURE_OPENAI_MODEL', 'gpt-4o-mini')})")
        else:
            print("Intent:       Disabled (set AZURE_OPENAI_ENDPOINT in .env to enable)")
        print("-" * 60)
        print("Type a message (or 'quit' to exit, 'stream:<msg>' for streaming):\n")

        client = A2AClient(httpx_client=httpx_client, agent_card=agent_card)

        while True:
            try:
                user_input = input("> ").strip()
            except (EOFError, KeyboardInterrupt):
                print("\nBye!")
                break

            if not user_input:
                continue
            if user_input.lower() in ("quit", "exit", "q"):
                print("Bye!")
                break

            streaming = user_input.lower().startswith("stream:")
            if streaming:
                user_input = user_input[7:].strip()

            # Intent detection: rewrite natural language → structured command
            message_text = user_input
            if intent_enabled:
                skill, argument = await detect_intent(user_input)
                rewritten = rewrite_for_agent(skill, argument, user_input)
                if rewritten != user_input:
                    print(f"  [intent: {skill}] → {rewritten}")
                message_text = rewritten

            payload: dict[str, Any] = {
                "message": {
                    "role": "user",
                    "parts": [{"kind": "text", "text": message_text}],
                    "messageId": uuid4().hex,
                },
            }

            try:
                if streaming:
                    request = SendStreamingMessageRequest(
                        id=str(uuid4()),
                        params=MessageSendParams(**payload),
                    )
                    async for chunk in client.send_message_streaming(request):
                        data = chunk.model_dump(mode="json", exclude_none=True)
                        _print_response(data)
                else:
                    request = SendMessageRequest(
                        id=str(uuid4()),
                        params=MessageSendParams(**payload),
                    )
                    response = await client.send_message(request)
                    data = response.model_dump(mode="json", exclude_none=True)
                    _print_response(data)
            except Exception as e:
                print(f"  Error: {e}")

            print()


def _print_response(data: dict) -> None:
    """Extract and print the agent's text response from A2A result payload."""
    result = data.get("result")
    if not result:
        error = data.get("error")
        if error:
            print(f"  Error: {error.get('message', error)}")
        return

    # Handle Task response
    status = result.get("status", {})
    message = status.get("message")
    if message:
        for part in message.get("parts", []):
            if part.get("kind") == "text":
                print(f"  {part['text']}")
                return

    # Handle direct Message response
    for part in result.get("parts", []):
        if part.get("kind") == "text":
            print(f"  {part['text']}")
            return

    # Fallback
    state = status.get("state", "unknown")
    print(f"  [Task state: {state}]")


if __name__ == "__main__":
    url = sys.argv[1] if len(sys.argv) > 1 else None
    asyncio.run(main(url))
