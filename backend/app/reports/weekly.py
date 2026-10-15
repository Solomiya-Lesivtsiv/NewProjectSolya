"""The weekly meetings report: a CSV for one ISO week, built from the database.

Nothing here knows about AWS. The worker (app.reports.worker) decides which week to build and
where the file goes. Two rules keep it safe to run more than once:
- the week is always a parameter, never "last week" in disguise, so an old report can be rebuilt;
- the same week always gives the same key (`reports/2026-W40.csv`), so building it twice
  overwrites one file instead of creating two.
"""

import csv
import io
import re
import uuid
from collections import Counter, defaultdict
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models import Meeting, User

# Weeks run Monday 00:00 to the next Monday 00:00 in this zone, like the calendar in the app.
REPORT_TZ = ZoneInfo("Europe/Kyiv")
LONGEST_COUNT = 5
WEEK_FORMAT = re.compile(r"(\d{4})-W(\d{2})")


def week_range(week: str) -> tuple[datetime, datetime]:
    """Start (included) and end (excluded) of an ISO week such as "2026-W40"."""
    match = WEEK_FORMAT.fullmatch(week)
    if match is None:
        raise ValueError(f"Not an ISO week like 2026-W40: {week!r}")
    try:
        monday = date.fromisocalendar(int(match[1]), int(match[2]), 1)
    except ValueError:
        raise ValueError(f"No such ISO week: {week!r}") from None
    return (
        datetime.combine(monday, time.min, tzinfo=REPORT_TZ),
        datetime.combine(monday + timedelta(days=7), time.min, tzinfo=REPORT_TZ),
    )


def iso_week(day: date) -> str:
    year, number, _ = day.isocalendar()
    return f"{year}-W{number:02d}"


def previous_week(today: date | None = None) -> str:
    """The ISO week before the one that contains `today` (default: today in Kyiv)."""
    today = today or datetime.now(REPORT_TZ).date()
    return iso_week(today - timedelta(days=7))


def report_key(week: str) -> str:
    """The S3 key of a week's report. Validates the week, so no odd text becomes part of a key."""
    week_range(week)
    return f"reports/{week}.csv"


def _hours(meeting: Meeting) -> float:
    return (meeting.ends_at - meeting.starts_at).total_seconds() / 3600


def _cell(text: str) -> str:
    """Stops a spreadsheet from running a title such as =HYPERLINK(...) as a formula."""
    return "'" + text if text[:1] in ("=", "+", "-", "@", "\t", "\r") else text


async def build_weekly_report(session: AsyncSession, week: str) -> bytes:
    """The CSV (UTF-8 with a BOM, so Excel shows Ukrainian titles correctly) for one ISO week.

    It holds the number of meetings and their hours for the week and the week before, the
    totals per owner, and the longest meetings."""
    start, end = week_range(week)
    previous_start = start - timedelta(days=7)

    result = await session.execute(
        select(Meeting, User.name)
        .join(User, User.id == Meeting.owner_id)
        .where(Meeting.starts_at >= previous_start, Meeting.starts_at < end)
        .options(selectinload(Meeting.participants))
    )
    this_week: list[Meeting] = []
    previous_count, previous_hours = 0, 0.0
    names: dict[uuid.UUID, str] = {}
    for meeting, owner_name in result.all():
        if meeting.starts_at >= start:
            this_week.append(meeting)
            names[meeting.owner_id] = owner_name
        else:
            previous_count += 1
            previous_hours += _hours(meeting)

    hours = sum(_hours(meeting) for meeting in this_week)
    owner_meetings = Counter(meeting.owner_id for meeting in this_week)
    owner_hours: defaultdict[uuid.UUID, float] = defaultdict(float)
    for meeting in this_week:
        owner_hours[meeting.owner_id] += _hours(meeting)
    owners = sorted(names, key=lambda owner: (-owner_hours[owner], names[owner]))
    longest = sorted(this_week, key=lambda m: (-_hours(m), m.starts_at, m.title))[:LONGEST_COUNT]

    out = io.StringIO()
    rows = csv.writer(out)
    rows.writerow(["Weekly meetings report", week])
    last_day = end - timedelta(days=1)
    rows.writerow(["Period", f"{start:%Y-%m-%d} to {last_day:%Y-%m-%d} ({REPORT_TZ.key})"])
    rows.writerow([])
    rows.writerow(["Summary", "Meetings", "Hours"])
    rows.writerow(["This week", len(this_week), f"{hours:.2f}"])
    rows.writerow(["Previous week", previous_count, f"{previous_hours:.2f}"])
    change_count, change_hours = len(this_week) - previous_count, hours - previous_hours
    rows.writerow(["Change", f"{change_count:+d}", f"{change_hours:+.2f}"])
    rows.writerow([])
    rows.writerow(["Owner", "Meetings", "Hours"])
    for owner in owners:
        rows.writerow([_cell(names[owner]), owner_meetings[owner], f"{owner_hours[owner]:.2f}"])
    rows.writerow([])
    rows.writerow(["Longest meetings", "Start", "Hours", "Participants"])
    for meeting in longest:
        local_start = meeting.starts_at.astimezone(REPORT_TZ)
        rows.writerow(
            [
                _cell(meeting.title),
                f"{local_start:%Y-%m-%d %H:%M}",
                f"{_hours(meeting):.2f}",
                len(meeting.participants),
            ]
        )
    return out.getvalue().encode("utf-8-sig")
