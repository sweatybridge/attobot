#!/usr/bin/env python3
"""Print SQL for bootstrapping an attobot agent in Postgres."""

import argparse


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


parser = argparse.ArgumentParser()
parser.add_argument("--slug", default="primary")
parser.add_argument("--api-key", required=True)
parser.add_argument(
    "--soul",
    default=(
        "You are a persistent agent running inside PostgreSQL. "
        "Be direct. Use tools when you need to act on stored state. "
        "Queue operator-facing messages with SEND_CHAT."
    ),
)
args = parser.parse_args()

print(
    "SELECT attobot.ensure_agent("
    f"p_slug => {sql_literal(args.slug)}, "
    f"p_soul => {sql_literal(args.soul)}, "
    f"p_api_key => {sql_literal(args.api_key)}"
    ");"
)
