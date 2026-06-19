#!/usr/bin/env python3
"""Thin CLI for the Postgres-resident attobot harness."""

import argparse
import os
import sys

import psycopg
from psycopg.rows import dict_row


DEFAULT_DSN = "postgresql://postgres:secret@localhost:5432/postgres"


def connect(args):
    return psycopg.connect(args.dsn or os.environ.get("ATTOBOT_DSN", DEFAULT_DSN), row_factory=dict_row)


def send(args):
    with connect(args) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT attobot.append_user_message(%s, %s) AS message_id",
                (args.agent, args.message),
            )
            message_id = cur.fetchone()["message_id"]
            cur.execute("SELECT attobot.start_turn(%s) AS durable_instance_id", (args.agent,))
            instance_id = cur.fetchone()["durable_instance_id"]
    print(f"queued message {message_id}; durable instance {instance_id}")


def outbox(args):
    with connect(args) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, created_at, channel, body
                FROM attobot.outbox
                WHERE agent_id = attobot.agent_id(%s)
                  AND status = 'pending'
                ORDER BY id
                LIMIT %s
                """,
                (args.agent, args.limit),
            )
            rows = cur.fetchall()
            if args.ack and rows:
                cur.execute(
                    "UPDATE attobot.outbox SET status = 'sent', sent_at = now() WHERE id = ANY(%s)",
                    ([row["id"] for row in rows],),
                )
    for row in rows:
        text = row["body"].get("text") if isinstance(row["body"], dict) else row["body"]
        print(f"{row['id']}\t{row['created_at']}\t{row['channel']}\t{text}")


def messages(args):
    with connect(args) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, created_at, role, coalesce(tool_call_id, '') AS tool_call_id, content
                FROM attobot.messages
                WHERE agent_id = attobot.agent_id(%s)
                ORDER BY id DESC
                LIMIT %s
                """,
                (args.agent, args.limit),
            )
            rows = list(reversed(cur.fetchall()))
    for row in rows:
        tool = f" tc:{row['tool_call_id']}" if row["tool_call_id"] else ""
        content = (row["content"] or "").replace("\n", "\\n")
        print(f"{row['id']}\t{row['created_at']}\t{row['role']}{tool}\t{content}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dsn")
    parser.add_argument("--agent", default="primary")
    sub = parser.add_subparsers(dest="command", required=True)

    send_parser = sub.add_parser("send")
    send_parser.add_argument("message")
    send_parser.set_defaults(func=send)

    outbox_parser = sub.add_parser("outbox")
    outbox_parser.add_argument("--limit", type=int, default=20)
    outbox_parser.add_argument("--ack", action="store_true")
    outbox_parser.set_defaults(func=outbox)

    messages_parser = sub.add_parser("messages")
    messages_parser.add_argument("--limit", type=int, default=40)
    messages_parser.set_defaults(func=messages)

    args = parser.parse_args()
    try:
        args.func(args)
    except psycopg.Error as exc:
        print(f"database error: {exc}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
