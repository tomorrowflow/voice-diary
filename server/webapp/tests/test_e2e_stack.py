"""E2E-1: the isolated e2e stack (server/docker-compose.e2e.yml, server/e2e/).

The fixture upstreams must keep answering in the shapes the webapp parses, and
the override must stay isolated from the prod stack.
"""

import importlib.util
import json
import re
import threading
from pathlib import Path

import httpx
import pytest

import document_processor

SERVER_DIR = Path(__file__).resolve().parents[2]
COMPOSE_E2E = SERVER_DIR / "docker-compose.e2e.yml"
STACK_SCRIPT = SERVER_DIR / "scripts" / "e2e_stack.py"
ENV_EXAMPLE = SERVER_DIR / ".env.e2e.example"
FIXTURE_UPSTREAMS = SERVER_DIR / "e2e" / "fixture_upstreams.py"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def stack():
    return _load("e2e_stack", STACK_SCRIPT)


@pytest.fixture(scope="module")
def upstreams():
    module = _load("fixture_upstreams", FIXTURE_UPSTREAMS)
    servers = {name: module._serve(name, 0) for name in ("ollama", "lightrag")}
    for server in servers.values():
        threading.Thread(target=server.serve_forever, daemon=True).start()
    urls = {name: f"http://127.0.0.1:{s.server_address[1]}" for name, s in servers.items()}
    yield module, urls
    for server in servers.values():
        server.shutdown()
        server.server_close()


def test_ollama_analysis_reply_parses_into_the_six_analysis_sections(upstreams):
    _, urls = upstreams
    resp = httpx.post(
        urls["ollama"] + "/v1/chat/completions",
        json={"messages": [{"role": "user", "content": "x"}], "response_format": {"type": "json_object"}},
    )
    content = document_processor._extract_chat_content(resp.json())
    assert set(json.loads(content)) == {
        "relationships", "projects", "decisions", "todos", "insights", "recurring_themes",
    }


def test_ollama_context_summary_is_long_enough_to_be_used(upstreams):
    _, urls = upstreams
    resp = httpx.post(
        urls["ollama"] + "/v1/chat/completions",
        json={"messages": [{"role": "user", "content": "Du bist ein Kontext-Komprimierer. ..."}]},
    )
    assert len(document_processor._extract_chat_content(resp.json())) >= 50


def test_ollama_native_chat_and_probe_routes_answer(upstreams):
    _, urls = upstreams
    chat = httpx.post(urls["ollama"] + "/api/chat", json={"messages": [{"role": "user", "content": "x"}]})
    assert chat.json()["message"]["content"]
    assert httpx.get(urls["ollama"] + "/api/tags").status_code == 200


def test_lightrag_routes_answer_and_requests_are_logged(upstreams):
    module, urls = upstreams
    assert httpx.get(urls["lightrag"] + "/health").status_code == 200
    assert httpx.post(urls["lightrag"] + "/query", json={"query": "q"}).json()["response"]
    assert httpx.post(
        urls["lightrag"] + "/documents/text", json={"id": "d", "text": "t", "file_source": "f"}
    ).status_code == 200
    assert httpx.request(
        "DELETE", urls["lightrag"] + "/documents/delete_document", json={"doc_ids": ["d"]}
    ).status_code == 200
    logged = {(e["service"], e["method"], e["path"]) for e in httpx.get(urls["lightrag"] + "/_fixture/requests").json()}
    assert {
        ("lightrag", "POST", "/query"),
        ("lightrag", "POST", "/documents/text"),
        ("lightrag", "DELETE", "/documents/delete_document"),
    } <= logged


def test_fixture_upstreams_use_only_the_invented_cast(upstreams):
    module, _ = upstreams
    text = json.dumps(module.ANALYSIS, ensure_ascii=False) + module.CONTEXT_SUMMARY
    assert "Jonas Falk" in text and "Mira Lindqvist" in text


def test_session_client_defaults_to_the_committed_speech_clip():
    client = _load("e2e_client", SERVER_DIR / "e2e" / "e2e_client.py")
    clip = client.DEFAULT_AUDIO.read_bytes()
    assert client.DEFAULT_AUDIO.parent == SERVER_DIR / "e2e"
    assert clip[4:8] == b"ftyp" and 10_000 < len(clip) < 500_000


def test_e2e_up_pulls_whisper_through_compose_and_waits_for_health(stack, monkeypatch, tmp_path):
    calls = []
    monkeypatch.setattr(stack, "ENV_FILE", tmp_path / ".env.e2e")
    (tmp_path / ".env.e2e").write_text("TAILNET_IP=100.64.0.1\n")
    monkeypatch.setattr(stack, "compose", lambda *args, **kw: calls.append(args))
    monkeypatch.setattr(stack, "client", lambda *args: calls.append(("client", *args)))
    stack.cmd_up()
    assert [c[0] for c in calls] == ["pull", "up", "client"]
    assert calls[0] == ("pull", "whisper") and calls[2] == ("client", "ready")


def test_e2e_override_is_isolated_from_the_prod_stack():
    compose = "\n".join(
        ln for ln in COMPOSE_E2E.read_text().splitlines() if not ln.lstrip().startswith("#")
    )
    assert re.search(r"^name: vd-e2e$", compose, re.MULTILINE)
    assert ":8100:8000" in compose and ":8000:8000" not in compose
    assert "- .env.e2e" in compose
    assert "MSGRAPH_FIXTURE_MODE=true" in compose
    # Nothing from the prod data dir or MSAL cache is mounted.
    assert not re.search(r"-\s*\./data\b", compose) and "msal" not in compose.lower()
    # Whisper is the CPU image with no GPU reservation; Voxtral never starts.
    assert "latest-gpu" not in compose and "deploy: !reset null" in compose
    assert compose.count('profiles: ["never"]') == 2


def test_e2e_script_scopes_every_compose_call_to_the_e2e_project(stack):
    cmd = stack.compose_command(["down", "-v"])
    assert cmd[:3] == ["docker", "compose", "-p"] and cmd[3] == "vd-e2e"
    assert cmd[cmd.index("--env-file") + 1].endswith("/.env.e2e")
    files = [cmd[i + 1] for i, a in enumerate(cmd) if a == "-f"]
    assert [Path(f).name for f in files] == ["docker-compose.yml", "docker-compose.e2e.yml"]
    assert cmd[-2:] == ["down", "-v"]
    # `compose_command` is the only place the script builds a docker call.
    assert STACK_SCRIPT.read_text().count('"docker", "compose"') == 1


def test_e2e_env_gets_fresh_secrets_and_keeps_the_example_shape(stack):
    example = ENV_EXAMPLE.read_text()
    first = stack.parse_env(stack.render_env(example, "100.64.0.1"))
    second = stack.parse_env(stack.render_env(example, "100.64.0.1"))
    assert first["TAILNET_IP"] == "100.64.0.1"
    assert first["MSGRAPH_FIXTURE_MODE"] == "true" and first["OLLAMA_BASE_URL"] == "http://upstreams:11434"
    for key in ("POSTGRES_PASSWORD", "IOS_BEARER_TOKEN"):
        assert re.fullmatch(r"[0-9a-f]{64}", first[key])
        assert first[key] != second[key]
    assert first["POSTGRES_PASSWORD"] != first["IOS_BEARER_TOKEN"]
    assert "<" not in stack.render_env(example, "100.64.0.1")
