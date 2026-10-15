import csv
import io
from collections.abc import AsyncIterator
from datetime import date, datetime, timedelta

import pytest
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models import Base, Meeting, Participant, User
from app.reports.weekly import (
    build_weekly_report,
    previous_week,
    report_key,
    week_range,
)


def test_week_range_is_monday_to_monday_in_kyiv() -> None:
    start, end = week_range("2026-W40")
    # Kyiv is UTC+3 until the end of October.
    assert start.isoformat() == "2026-09-28T00:00:00+03:00"
    assert end.isoformat() == "2026-10-05T00:00:00+03:00"


def test_week_range_follows_the_clock_change() -> None:
    # Daylight saving time ends on 25 October 2026: that week is one hour longer.
    start, end = week_range("2026-W43")
    assert start.utcoffset() == timedelta(hours=3)
    assert end.utcoffset() == timedelta(hours=2)
    assert end - start == timedelta(days=7)  # wall-clock arithmetic, as the calendar counts days


@pytest.mark.parametrize("week", ["", "2026-40", "2026-W5", "2026-W00", "2026-W54", "x/2026-W40"])
def test_week_range_rejects_anything_but_a_real_iso_week(week: str) -> None:
    with pytest.raises(ValueError):
        week_range(week)


def test_2026_has_53_weeks() -> None:
    assert week_range("2026-W53")[0].date() == date(2026, 12, 28)


@pytest.mark.parametrize(
    ("today", "expected"),
    [
        (date(2026, 10, 7), "2026-W40"),  # Wednesday of W41
        (date(2026, 10, 5), "2026-W40"),  # Monday of W41: the report runs now
        (date(2027, 1, 4), "2026-W53"),  # Monday of 2027-W01
    ],
)
def test_previous_week(today: date, expected: str) -> None:
    assert previous_week(today) == expected


def test_report_key_is_one_file_per_week() -> None:
    assert report_key("2026-W40") == "reports/2026-W40.csv"
    with pytest.raises(ValueError):
        report_key("../2026-W40")


@pytest.fixture
async def session(engine) -> AsyncIterator[AsyncSession]:
    async with engine.begin() as conn:
        for table in reversed(Base.metadata.sorted_tables):
            await conn.execute(table.delete())
    async with async_sessionmaker(engine, expire_on_commit=False)() as session:
        yield session


def meeting(owner: User, title: str, start: str, end: str, people=()) -> Meeting:
    return Meeting(
        title=title,
        starts_at=datetime.fromisoformat(start),
        ends_at=datetime.fromisoformat(end),
        place="Room 1",
        owner_id=owner.id,
        participants=list(people),
    )


def read_rows(data: bytes) -> list[list[str]]:
    # utf-8-sig: the file starts with a BOM so that Excel reads it as UTF-8.
    return list(csv.reader(io.StringIO(data.decode("utf-8-sig"))))


async def test_report_for_a_week(session: AsyncSession) -> None:
    alice = User(cognito_sub="alice", email="alice@example.com", name="Alice")
    bob = User(cognito_sub="bob", email="bob@example.com", name="Bob")
    people = [
        Participant(name=n, email=f"{n.lower()}@example.com") for n in ("Olena", "Taras", "Ira")
    ]
    session.add_all([alice, bob, *people])
    await session.flush()
    session.add_all(
        [
            # 2026-W40 (28 Sep - 4 Oct), Kyiv time.
            meeting(
                alice,
                "Sprint planning",
                "2026-09-28T10:00+03:00",
                "2026-09-28T11:00+03:00",
                people[:2],
            ),
            meeting(bob, "Standup", "2026-09-29T09:00+03:00", "2026-09-29T09:30+03:00"),
            meeting(alice, "Retro", "2026-09-30T14:00+03:00", "2026-09-30T16:30+03:00"),
            meeting(alice, "Coffee", "2026-10-01T09:00+03:00", "2026-10-01T09:15+03:00"),
            meeting(alice, "Workshop", "2026-10-02T09:00+03:00", "2026-10-02T13:00+03:00", people),
            # The last half hour of the week still counts.
            meeting(alice, "Late call", "2026-10-04T23:00+03:00", "2026-10-04T23:30+03:00"),
            # 2026-W39: the week before.
            meeting(alice, "Old meeting", "2026-09-22T10:00+03:00", "2026-09-22T12:00+03:00"),
            # Outside both weeks: just after the boundary, and two weeks earlier.
            meeting(alice, "Next week", "2026-10-05T00:30+03:00", "2026-10-05T01:30+03:00"),
            meeting(alice, "Long ago", "2026-09-15T10:00+03:00", "2026-09-15T11:00+03:00"),
        ]
    )
    await session.commit()

    rows = read_rows(await build_weekly_report(session, "2026-W40"))

    assert rows == [
        ["Weekly meetings report", "2026-W40"],
        ["Period", "2026-09-28 to 2026-10-04 (Europe/Kyiv)"],
        [],
        ["Summary", "Meetings", "Hours"],
        ["This week", "6", "8.75"],
        ["Previous week", "1", "2.00"],
        ["Change", "+5", "+6.75"],
        [],
        ["Owner", "Meetings", "Hours"],
        ["Alice", "5", "8.25"],
        ["Bob", "1", "0.50"],
        [],
        ["Longest meetings", "Start", "Hours", "Participants"],
        ["Workshop", "2026-10-02 09:00", "4.00", "3"],
        ["Retro", "2026-09-30 14:00", "2.50", "0"],
        ["Sprint planning", "2026-09-28 10:00", "1.00", "2"],
        ["Standup", "2026-09-29 09:00", "0.50", "0"],
        ["Late call", "2026-10-04 23:00", "0.50", "0"],
    ]


async def test_same_week_gives_the_same_file(session: AsyncSession) -> None:
    alice = User(cognito_sub="alice", email="alice@example.com", name="Alice")
    session.add(alice)
    await session.flush()
    session.add(meeting(alice, "Retro", "2026-09-30T14:00+03:00", "2026-09-30T16:30+03:00"))
    await session.commit()

    first = await build_weekly_report(session, "2026-W40")
    second = await build_weekly_report(session, "2026-W40")

    assert first == second


async def test_empty_week_still_has_a_report(session: AsyncSession) -> None:
    rows = read_rows(await build_weekly_report(session, "2026-W40"))

    assert ["This week", "0", "0.00"] in rows
    assert ["Change", "+0", "+0.00"] in rows
    assert rows[-1] == ["Longest meetings", "Start", "Hours", "Participants"]


async def test_titles_cannot_become_spreadsheet_formulas(session: AsyncSession) -> None:
    alice = User(cognito_sub="alice", email="alice@example.com", name="Alice")
    session.add(alice)
    await session.flush()
    session.add(
        meeting(
            alice, '=HYPERLINK("http://evil")', "2026-09-30T14:00+03:00", "2026-09-30T15:00+03:00"
        )
    )
    await session.commit()

    rows = read_rows(await build_weekly_report(session, "2026-W40"))

    assert rows[-1][0] == '\'=HYPERLINK("http://evil")'
