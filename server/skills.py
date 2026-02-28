import base64
import hashlib
import uuid


def generate_uuid() -> str:
    """Generate a new UUID v4."""
    return str(uuid.uuid4())


def hash_text(text: str) -> str:
    """Return the SHA-256 hex digest of the given text."""
    return hashlib.sha256(text.encode()).hexdigest()


def base64_encode(text: str) -> str:
    """Base64-encode the given text."""
    return base64.b64encode(text.encode()).decode()


def base64_decode(text: str) -> str:
    """Base64-decode the given text."""
    return base64.b64decode(text.encode()).decode()


def word_count(text: str) -> str:
    """Count words and characters in the given text."""
    words = len(text.split())
    chars = len(text)
    return f"Words: {words}, Characters: {chars}"


# Maps skill id → (function, needs_argument)
SKILL_REGISTRY: dict[str, tuple] = {
    "generate_uuid": (generate_uuid, False),
    "hash_text": (hash_text, True),
    "base64_encode": (base64_encode, True),
    "base64_decode": (base64_decode, True),
    "word_count": (word_count, True),
}


def route_request(user_text: str) -> str:
    """Route a user message to the appropriate skill based on keyword matching."""
    lower = user_text.lower().strip()

    # Try explicit "skill: argument" format first
    for skill_id in SKILL_REGISTRY:
        prefix = skill_id.replace("_", " ") + ":"
        alt_prefix = skill_id + ":"
        for p in (prefix, alt_prefix):
            if lower.startswith(p):
                arg = user_text[len(p) :].strip()
                fn, needs_arg = SKILL_REGISTRY[skill_id]
                return fn(arg) if needs_arg else fn()

    # Keyword-based routing
    if any(kw in lower for kw in ("uuid", "guid", "unique id")):
        return generate_uuid()
    if any(kw in lower for kw in ("hash", "sha256", "sha-256", "checksum")):
        # Extract text after the keyword
        arg = _extract_arg(user_text, ("hash", "sha256", "sha-256", "checksum"))
        return hash_text(arg) if arg else "Please provide text to hash. Example: hash: hello world"
    if any(kw in lower for kw in ("base64 encode", "b64 encode", "encode to base64")):
        arg = _extract_arg(user_text, ("base64 encode", "b64 encode", "encode to base64"))
        return base64_encode(arg) if arg else "Please provide text to encode. Example: base64 encode: hello"
    if any(kw in lower for kw in ("base64 decode", "b64 decode", "decode base64", "decode from base64")):
        arg = _extract_arg(user_text, ("base64 decode", "b64 decode", "decode base64", "decode from base64"))
        return base64_decode(arg) if arg else "Please provide text to decode. Example: base64 decode: aGVsbG8="
    if any(kw in lower for kw in ("word count", "count words", "character count", "count characters", "wc")):
        arg = _extract_arg(user_text, ("word count", "count words", "character count", "count characters", "wc"))
        return word_count(arg) if arg else "Please provide text to count. Example: word count: hello world"

    return (
        "I can help with these text utilities:\n"
        "• generate uuid — Generate a UUID v4\n"
        "• hash: <text> — SHA-256 hash\n"
        "• base64 encode: <text> — Base64 encode\n"
        "• base64 decode: <text> — Base64 decode\n"
        "• word count: <text> — Count words & characters\n\n"
        "Try: 'generate a uuid' or 'hash: hello world'"
    )


def _extract_arg(text: str, keywords: tuple[str, ...]) -> str:
    """Extract the argument after a keyword, handling optional colon separator."""
    lower = text.lower()
    for kw in keywords:
        idx = lower.find(kw)
        if idx != -1:
            after = text[idx + len(kw) :].strip()
            if after.startswith(":"):
                after = after[1:].strip()
            return after
    return ""
