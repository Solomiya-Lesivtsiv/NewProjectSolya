import json
from collections.abc import AsyncIterator

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.db import get_session
from app.models import Base, User
from app.reports.weekly import previous_week
from app.reports.worker import app, get_store
from tests.test_reports import meeting


class FakeStore:
    def __init__(self) -> None:
        self.files: dict[str, bytes] = {}

    async def put(self, key: str, data: bytes) -> None:
        self.files[key] = data


@pytest.fixture
async def worker(engine) -> AsyncIterator[tuple[AsyncClient, FakeStore]]:
    async with engine.begin() as conn:
        for table in reversed(Base.metadata.sorted_tables):
            await conn.execute(table.delete())
    sessionmaker = async_sessionmaker(engine, expire_on_commit=False)

    async def override_session() -> AsyncIterator[AsyncSession]:
        async with sessionmaker() as session:
            yield session

    store = FakeStore()
    app.dependency_overrides[get_session] = override_session
    app.dependency_overrides[get_store] = lambda: store
    # An error in the app is a 500 response, as on the real server, and not a raised exception.
    transport = ASGITransport(app=app, raise_app_exceptions=False)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        async with sessionmaker() as session:
            alice = User(cognito_sub="alice", email="alice@example.com", name="Alice")
            session.add(alice)
            await session.flush()
            session.add(meeting(alice, "Retro", "2026-09-30T14:00+03:00", "2026-09-30T16:30+03:00"))
            await session.commit()
        yield client, store
    app.dependency_overrides.clear()


def sqs_event(body: dict) -> dict:
    return {"Records": [{"eventSource": "aws:sqs", "messageId": "1", "body": json.dumps(body)}]}


async def test_health(worker) -> None:
    client, _ = worker
    assert (await client.get("/api/health")).json() == {"status": "ok"}


async def test_the_worker_has_no_docs_or_api(worker) -> None:
    client, _ = worker
    for path in ("/docs", "/openapi.json", "/api/meetings"):
        assert (await client.get(path)).status_code == 404


async def test_sqs_message_builds_the_week_and_stores_the_file(worker, caplog) -> None:
    client, store = worker
    caplog.set_level("INFO", logger="report-builder")

    response = await client.post(
        "/events", json=sqs_event({"week": "2026-W40", "source": "report-now"})
    )

    assert response.status_code == 200, response.text
    assert response.json() == {"reports": [{"week": "2026-W40", "key": "reports/2026-W40.csv"}]}
    assert list(store.files) == ["reports/2026-W40.csv"]
    assert b"Retro" in store.files["reports/2026-W40.csv"]
    assert "trigger=sqs week=2026-W40 source=report-now" in caplog.text


async def test_schedule_message_builds_the_previous_week(worker, caplog) -> None:
    client, store = worker
    caplog.set_level("INFO", logger="report-builder")

    response = await client.post("/events", json=sqs_event({"week": None, "source": "schedule"}))

    assert response.status_code == 200, response.text
    expected = previous_week()
    assert list(store.files) == [f"reports/{expected}.csv"]
    assert f"trigger=schedule week={expected} source=schedule" in caplog.text


async def test_direct_invocation(worker, caplog) -> None:
    client, store = worker
    caplog.set_level("INFO", logger="report-builder")

    response = await client.post("/events", json={"week": "2026-W40"})

    assert response.status_code == 200, response.text
    assert "reports/2026-W40.csv" in store.files
    assert "trigger=direct week=2026-W40" in caplog.text


async def test_same_week_twice_is_one_file(worker) -> None:
    client, store = worker
    for _ in range(2):
        await client.post("/events", json=sqs_event({"week": "2026-W40", "source": "report-now"}))

    assert list(store.files) == ["reports/2026-W40.csv"]


@pytest.mark.parametrize(
    "event",
    [
        sqs_event({"week": "not-a-week"}),
        sqs_event({"week": "../2026-W40"}),
        {"Records": [{"eventSource": "aws:sns", "body": "{}"}]},
        {"Records": [{"eventSource": "aws:sqs", "body": "not json"}]},
    ],
)
async def test_bad_messages_fail_so_they_reach_the_dead_letter_queue(worker, event) -> None:
    client, store = worker
    response = await client.post("/events", json=event)

    assert response.status_code == 500
    assert store.files == {}
