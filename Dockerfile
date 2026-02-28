FROM python:3.12-slim AS base

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

# Install dependencies first (layer caching)
COPY pyproject.toml uv.lock .python-version ./
RUN uv sync --frozen --no-dev --no-install-project

# Copy application code
COPY README.md ./
COPY server/ server/
COPY client/ client/
RUN uv sync --frozen --no-dev

EXPOSE 8000

CMD ["uv", "run", "python", "-m", "server"]
