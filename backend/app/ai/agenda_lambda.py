"""The agenda parser: the app that runs inside the agenda-parser Lambda function.

Same container image as the API, started with another command
(`uvicorn app.ai.agenda_lambda:app`) and reached through its own public function URL. It needs no
database, so it runs outside the VPC and calls Bedrock directly. It only parses: it returns JSON
and never writes anything; saving goes through the normal API.

Every call costs money, so it is authenticated (Cognito ID token, as in the API), limited to
10,000 characters of text, and logs one JSON line per parse.
"""

import asyncio
import json
import logging
import time
from datetime import date
from typing import Annotated

import anthropic
from botocore.exceptions import ClientError
from fastapi import Depends, FastAPI, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field

from app.ai.agenda import PROMPT_VERSION, AgendaParseError, active_model, cost_usd, parse_agenda
from app.auth import InvalidTokenError, TokenVerifier, get_verifier
from app.config import settings

MAX_TEXT_CHARS = 10_000

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("agenda-parser")

app = FastAPI(title="Agenda parser", docs_url=None, redoc_url=None, openapi_url=None)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_methods=["POST"],
    allow_headers=["authorization", "content-type"],
)

bearer = HTTPBearer(auto_error=False)


class ParseRequest(BaseModel):
    text: str
    # The user's "Monday" is in the user's time zone; this function runs in UTC.
    today: date
    tz: str = Field(max_length=64)


async def current_user(
    verifier: Annotated[TokenVerifier, Depends(get_verifier)],
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
) -> str:
    """The Cognito user id (sub). There is no database here, so no user row is looked up."""
    unauthorized = HTTPException(
        status.HTTP_401_UNAUTHORIZED,
        "Invalid or expired token",
        headers={"WWW-Authenticate": "Bearer"},
    )
    if credentials is None:
        raise unauthorized
    try:
        claims = await verifier.verify(credentials.credentials)
    except InvalidTokenError:
        raise unauthorized from None
    return claims["sub"]


@app.get("/api/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/api/parse-agenda")
async def parse(body: ParseRequest, user: Annotated[str, Depends(current_user)]) -> dict:
    if len(body.text) > MAX_TEXT_CHARS:
        raise HTTPException(
            status.HTTP_413_CONTENT_TOO_LARGE, f"Text is longer than {MAX_TEXT_CHARS} characters"
        )
    if not body.text.strip():
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Text is empty")

    started = time.monotonic()
    try:
        # The Bedrock client is synchronous; keep the event loop free.
        agenda, usage = await asyncio.to_thread(parse_agenda, body.text, body.today, body.tz)
    except AgendaParseError as error:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(error)) from error
    except anthropic.RateLimitError:
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "The service is busy") from None
    except anthropic.APIError:
        log.exception("Bedrock call failed")
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, "The model is unavailable") from None
    except ClientError as error:  # the Converse API (PARSER_PROVIDER=converse)
        if error.response["Error"]["Code"] == "ThrottlingException":
            raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "The service is busy") from None
        log.exception("Bedrock call failed")
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, "The model is unavailable") from None

    log.info(
        json.dumps(
            {
                "event": "agenda_parsed",
                "user": user,
                "model": active_model(),
                "prompt_version": PROMPT_VERSION,
                **usage,
                "latency_ms": int((time.monotonic() - started) * 1000),
                "cost_usd": cost_usd(active_model(), usage),
            }
        )
    )
    return {
        "agenda": agenda.model_dump(mode="json"),
        "model": active_model(),
        "prompt_version": PROMPT_VERSION,
    }
