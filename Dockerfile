FROM python:3.12-slim AS base

# attobot deps
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

WORKDIR /attobot

FROM base AS setup

COPY --parents setup.py SOUL.md opt ./

ENTRYPOINT ["python", "-u", "setup.py"]

FROM base AS agent

# attobot source
COPY agent.py ./

# Just run the agent — the LLM server (Ollama) runs on the host
ENTRYPOINT ["python", "-u", "agent.py"]
