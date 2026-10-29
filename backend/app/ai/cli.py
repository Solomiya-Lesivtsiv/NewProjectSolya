"""Run the parser from your laptop: `make llm-hello` and `make parse TEXT="..."`."""

import json
import sys
import time
from datetime import date

from app.ai.agenda import PROMPT_VERSION, active_model, cost_usd, get_client, parse_agenda
from app.config import settings


def hello() -> None:
    msg = get_client().messages.create(
        model=settings.parser_model,
        max_tokens=1024,
        output_config={"effort": settings.parser_effort},
        messages=[{"role": "user", "content": "In one sentence: what is an ISO week?"}],
    )
    print(next(b.text for b in msg.content if b.type == "text"))
    print(msg.stop_reason, msg.usage.input_tokens, msg.usage.output_tokens)


def parse(text: str, tz: str = "Europe/Kyiv") -> None:
    started = time.monotonic()
    agenda, usage = parse_agenda(text, date.today(), tz)
    print(json.dumps(agenda.model_dump(mode="json"), ensure_ascii=False, indent=2))
    print(
        json.dumps(
            {
                "model": active_model(),
                "prompt_version": PROMPT_VERSION,
                **usage,
                "latency_ms": int((time.monotonic() - started) * 1000),
                "cost_usd": cost_usd(active_model(), usage),
            }
        )
    )


if __name__ == "__main__":
    command, *rest = sys.argv[1:] or ["hello"]
    if command == "hello":
        hello()
    else:
        parse(" ".join(rest))
