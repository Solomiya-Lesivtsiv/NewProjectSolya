"""The report builder: the app that runs inside the report-builder Lambda function.

It is the same container image as the API, started with another command
(`uvicorn app.reports.worker:app`). The Lambda Web Adapter hands every event that is not a web
request, an SQS message or a direct invocation, to this app as `POST /events` (the event is the
JSON body). This app is not the public API: the builder function has no function URL, so only
Lambda itself can reach `/events`.

Events it understands:
- SQS message from the schedule or from `make report-now`: the body is JSON,
  `{"week": "2026-W39" | null, "source": "schedule" | "report-now"}`;
- a direct invocation with the same JSON (`{"source": "schedule"}`).
No week means the previous ISO week.

A failure is a 500, which the adapter turns into a function error (AWS_LWA_ERROR_STATUS_CODES),
so SQS delivers the message again and, after three attempts, moves it to the dead-letter queue.
"""

import asyncio
import json
import logging
from functools import cache
from typing import Annotated, Any

import boto3
from fastapi import Depends, FastAPI
from pydantic import BaseModel, ValidationError

from app.config import settings
from app.db import SessionDep
from app.reports.weekly import build_weekly_report, previous_week, report_key

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s")
log = logging.getLogger("report-builder")

# No docs and no OpenAPI: nothing here is meant to be browsed.
app = FastAPI(title="Report builder", docs_url=None, redoc_url=None, openapi_url=None)


class ReportRequest(BaseModel):
    """What to build. Anything missing means "last week, started by someone unknown"."""

    week: str | None = None
    source: str = "unknown"


class ReportStore:
    """Where finished reports go: the reports bucket on S3."""

    def __init__(self, bucket: str) -> None:
        self.bucket = bucket
        self._s3 = boto3.client("s3")

    async def put(self, key: str, data: bytes) -> None:
        await asyncio.to_thread(
            self._s3.put_object,
            Bucket=self.bucket,
            Key=key,
            Body=data,
            ContentType="text/csv; charset=utf-8",
        )


@cache
def get_store() -> ReportStore:
    if not settings.reports_bucket:
        raise RuntimeError("REPORTS_BUCKET is not set")
    return ReportStore(settings.reports_bucket)


StoreDep = Annotated[ReportStore, Depends(get_store)]


def requests_in(event: dict[str, Any]) -> list[tuple[str, ReportRequest]]:
    """The (trigger, request) pairs in an event.

    The trigger says what started the function: "schedule" for the weekly schedule, "sqs" for
    any other queue message (make report-now), "direct" for a plain invocation."""
    records = event.get("Records")
    if records is None:
        # Direct invocation: the event is the request.
        request = ReportRequest.model_validate(event)
        return [("schedule" if request.source == "schedule" else "direct", request)]
    found = []
    for record in records:
        if record.get("eventSource") != "aws:sqs":
            raise ValueError(f"Unsupported event source: {record.get('eventSource')!r}")
        request = ReportRequest.model_validate(json.loads(record["body"]))
        found.append(("schedule" if request.source == "schedule" else "sqs", request))
    return found


@app.get("/api/health")
async def health() -> dict[str, str]:
    # The adapter waits for this to answer before it forwards the first event.
    return {"status": "ok"}


@app.post("/events")
async def events(event: dict[str, Any], session: SessionDep, store: StoreDep) -> dict[str, Any]:
    try:
        todo = requests_in(event)
    except (ValueError, ValidationError) as error:
        # Poison message: fail, so that it ends up in the dead-letter queue and not in a loop
        # of silent successes.
        log.error("report-builder cannot read the event: %s", error)
        raise
    reports = []
    for trigger, request in todo:
        week = request.week or previous_week()
        key = report_key(week)  # also validates the week
        log.info(
            "report-builder triggered trigger=%s week=%s source=%s key=%s",
            trigger,
            week,
            request.source,
            key,
        )
        data = await build_weekly_report(session, week)
        await store.put(key, data)
        log.info("report-builder wrote key=%s bytes=%d", key, len(data))
        reports.append({"week": week, "key": key})
    return {"reports": reports}
