"""The agenda parser, tested without Bedrock: the model is a fake that returns canned answers."""

from datetime import date
from types import SimpleNamespace

import pytest
from httpx import ASGITransport, AsyncClient

from app.ai import agenda, agenda_lambda
from app.auth import TokenVerifier, get_verifier
from tests.conftest import CLIENT_ID, JWKS, POOL_ID, make_token

GOOD = {
    "title": "Синк по прайсингу",
    "starts_at": "2026-10-19T10:00:00+03:00",
    "duration_minutes": 45,
    "items": [{"topic": "нові тарифи Pro", "owner": "Олена", "minutes": 15}],
    "language": "uk",
}


class FakeClient:
    """Plays back one answer per call: a dict is a record_agenda call, None is plain text."""

    def __init__(self, *answers: dict | None) -> None:
        self.answers = list(answers)
        self.calls = 0
        self.messages = self

    def create(self, **kwargs):
        self.calls += 1
        answer = self.answers.pop(0)
        usage = SimpleNamespace(input_tokens=100, output_tokens=50)
        if answer is None:
            return SimpleNamespace(content=[], stop_reason="refusal", usage=usage)
        block = SimpleNamespace(type="tool_use", id=f"call-{self.calls}", input=answer)
        return SimpleNamespace(content=[block], stop_reason="tool_use", usage=usage)


@pytest.fixture
def fake_model(monkeypatch):
    def install(*answers):
        fake = FakeClient(*answers)
        monkeypatch.setattr(agenda, "get_client", lambda: fake)
        return fake

    return install


def test_parse_returns_validated_agenda_and_usage(fake_model):
    fake_model(GOOD)
    parsed, usage = agenda.parse_agenda("...", date(2026, 10, 15), "Europe/Kyiv")
    assert parsed.items[0].owner == "Олена"
    assert parsed.action_items == []
    assert usage == {"input_tokens": 100, "output_tokens": 50}


def test_invalid_output_is_retried_once_with_the_error(fake_model):
    fake = fake_model({"items": [{"topic": "x", "minutes": 9999}], "language": "uk"}, GOOD)
    parsed, usage = agenda.parse_agenda("...", date(2026, 10, 15), "UTC")
    assert fake.calls == 2
    assert parsed.title == GOOD["title"]
    assert usage["input_tokens"] == 200  # both calls are counted


def test_two_invalid_answers_give_up(fake_model):
    bad = {"items": [{"topic": ""}], "language": "uk"}
    fake_model(bad, bad)
    with pytest.raises(agenda.AgendaParseError, match="invalid agenda twice"):
        agenda.parse_agenda("...", date(2026, 10, 15), "UTC")


def test_no_tool_call_is_an_error(fake_model):
    fake_model(None)
    with pytest.raises(agenda.AgendaParseError, match="refusal"):
        agenda.parse_agenda("...", date(2026, 10, 15), "UTC")


def test_cost_uses_the_price_of_the_model():
    usage = {"input_tokens": 1_000_000, "output_tokens": 1_000_000}
    assert agenda.cost_usd("anthropic.claude-haiku-5-5", usage) == 0.6
    assert agenda.cost_usd("anthropic.claude-opus-5-5", usage) == 24.0
    assert agenda.cost_usd("unknown-model", usage) == 0.0


@pytest.fixture
async def parser():
    verifier = TokenVerifier(POOL_ID, CLIENT_ID, JWKS)
    agenda_lambda.app.dependency_overrides[get_verifier] = lambda: verifier
    headers = {"Authorization": f"Bearer {make_token('alice')}"}
    async with AsyncClient(
        transport=ASGITransport(app=agenda_lambda.app), base_url="http://test", headers=headers
    ) as client:
        yield client
    agenda_lambda.app.dependency_overrides.clear()


BODY = {"text": "Пн 10:00, синк", "today": "2026-10-15", "tz": "Europe/Kyiv"}


async def test_parse_endpoint(parser, fake_model, caplog):
    fake_model(GOOD)
    with caplog.at_level("INFO", logger="agenda-parser"):
        response = await parser.post("/api/parse-agenda", json=BODY)
    assert response.status_code == 200
    assert response.json()["agenda"]["duration_minutes"] == 45
    assert response.json()["prompt_version"] == agenda.PROMPT_VERSION
    assert '"event": "agenda_parsed"' in caplog.text and '"cost_usd"' in caplog.text


async def test_requires_a_token(parser):
    response = await parser.post("/api/parse-agenda", json=BODY, headers={"Authorization": ""})
    assert response.status_code == 401
    response = await parser.post(
        "/api/parse-agenda", json=BODY, headers={"Authorization": "Bearer nonsense"}
    )
    assert response.status_code == 401


async def test_too_long_text_is_rejected_before_the_model(parser, fake_model):
    fake = fake_model()
    response = await parser.post(
        "/api/parse-agenda", json={**BODY, "text": "x" * (agenda_lambda.MAX_TEXT_CHARS + 1)}
    )
    assert response.status_code == 413
    assert fake.calls == 0


async def test_unparsable_text_is_a_422(parser, fake_model):
    fake_model(None)
    response = await parser.post("/api/parse-agenda", json=BODY)
    assert response.status_code == 422


def test_openai_fallback_uses_the_same_contract(monkeypatch):
    monkeypatch.setattr(agenda.settings, "parser_provider", "openai")
    monkeypatch.setattr(agenda.settings, "openai_api_key", "sk-test")
    import json

    def reply(arguments):
        call = {
            "id": "c1",
            "function": {"name": "record_agenda", "arguments": json.dumps(arguments)},
        }
        return {
            "choices": [{"message": {"tool_calls": [call]}, "finish_reason": "tool_calls"}],
            "usage": {"prompt_tokens": 100, "completion_tokens": 50},
        }

    answers = [reply({"items": [{"topic": ""}], "language": "uk"}), reply(GOOD)]
    monkeypatch.setattr(agenda, "_openai_chat", lambda payload: answers.pop(0))
    parsed, usage = agenda.parse_agenda("...", date(2026, 10, 15), "UTC")
    assert parsed.items[0].owner == "Олена"
    assert usage == {"input_tokens": 200, "output_tokens": 100}
    assert agenda.active_model() == "gpt-4o-mini"


def test_converse_uses_the_same_contract(monkeypatch):
    monkeypatch.setattr(agenda.settings, "parser_provider", "converse")
    monkeypatch.setattr(agenda.settings, "parser_model", "us.amazon.nova-2-lite-v1:0")

    def reply(arguments):
        call = {"toolUse": {"toolUseId": "t1", "name": "record_agenda", "input": arguments}}
        return {
            "output": {"message": {"role": "assistant", "content": [call]}},
            "stopReason": "tool_use",
            "usage": {"inputTokens": 100, "outputTokens": 50},
        }

    answers = [reply({"items": [{"topic": ""}], "language": "uk"}), reply(GOOD)]
    requests = []

    class FakeRuntime:
        def converse(self, **kwargs):
            requests.append(kwargs)
            return answers.pop(0)

    monkeypatch.setattr(agenda, "get_converse_client", lambda: FakeRuntime())
    parsed, usage = agenda.parse_agenda("...", date(2026, 10, 15), "UTC")
    assert parsed.items[0].owner == "Олена"
    assert usage == {"input_tokens": 200, "output_tokens": 100}
    # The second request shows the model its validation error.
    assert requests[1]["messages"][-1]["content"][0]["toolResult"]["status"] == "error"
    assert agenda.cost_usd(agenda.active_model(), usage) > 0
