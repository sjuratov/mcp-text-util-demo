"""Intent detection using Azure OpenAI with Entra ID authentication."""

import json
import os

from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from openai import AsyncAzureOpenAI


SYSTEM_PROMPT = """\
You are an intent classifier for a text utilities agent. Given a user message, determine which skill to invoke and extract the argument.

Available skills:
- generate_uuid: Generate a UUID v4. No argument needed.
- hash_text: SHA-256 hash of text. Argument: the text to hash.
- base64_encode: Base64-encode text. Argument: the text to encode.
- base64_decode: Base64-decode text. Argument: the base64 string to decode.
- word_count: Count words and characters. Argument: the text to count.
- unknown: The message doesn't match any skill.

Respond with JSON only, no markdown:
{"skill": "<skill_id>", "argument": "<extracted_argument_or_empty>"}

Examples:
User: "Can you make me a unique identifier?"
{"skill": "generate_uuid", "argument": ""}

User: "What's the sha hash of my secret password123?"
{"skill": "hash_text", "argument": "my secret password123"}

User: "Encode the phrase 'hello world' in base64"
{"skill": "base64_encode", "argument": "hello world"}

User: "How many words are in: the quick brown fox jumps over the lazy dog"
{"skill": "word_count", "argument": "the quick brown fox jumps over the lazy dog"}

User: "What's the weather today?"
{"skill": "unknown", "argument": ""}
"""


def _build_client() -> AsyncAzureOpenAI:
    credential = DefaultAzureCredential()
    token_provider = get_bearer_token_provider(
        credential,
        "https://cognitiveservices.azure.com/.default",
    )
    return AsyncAzureOpenAI(
        azure_endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],
        api_version=os.environ.get("AZURE_OPENAI_API_VERSION", "2024-12-01-preview"),
        azure_ad_token_provider=token_provider,
    )


async def detect_intent(user_text: str) -> tuple[str, str]:
    """Detect the user's intent via Azure OpenAI.

    Returns:
        (skill_id, argument) tuple. skill_id is "unknown" if no match.
    """
    client = _build_client()
    model = os.environ.get("AZURE_OPENAI_MODEL", "gpt-4o-mini")

    try:
        response = await client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_text},
            ],
            temperature=0,
            max_tokens=150,
        )

        content = response.choices[0].message.content.strip()
        parsed = json.loads(content)
        return parsed.get("skill", "unknown"), parsed.get("argument", "")
    except Exception as e:
        print(f"  [Intent detection failed: {e} — falling back to raw input]")
        return "unknown", ""
    finally:
        await client.close()


def rewrite_for_agent(skill: str, argument: str, original: str) -> str:
    """Rewrite user input into the structured format the agent expects."""
    if skill == "generate_uuid":
        return "generate a uuid"
    elif skill == "hash_text":
        return f"hash: {argument}"
    elif skill == "base64_encode":
        return f"base64 encode: {argument}"
    elif skill == "base64_decode":
        return f"base64 decode: {argument}"
    elif skill == "word_count":
        return f"word count: {argument}"
    else:
        return original
