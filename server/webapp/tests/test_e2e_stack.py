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
        json={"messages": [{"role": "user", "content": "Du analysierst das Tagebuch eines CTOs vom 2026-01-01."}]},
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
    text = json.dumps(module.cast_analysis("2026-01-01"), ensure_ascii=False) + module.CONTEXT_SUMMARY
    assert "Jonas Falk" in text and "Mira Lindqvist" in text


def test_session_client_defaults_to_the_committed_speech_clip():
    client = _load("e2e_client", SERVER_DIR / "e2e" / "e2e_client.py")
    clip = client.DEFAULT_AUDIO.read_bytes()
    assert client.DEFAULT_AUDIO.parent == SERVER_DIR / "e2e"
    assert clip[4:8] == b"ftyp" and 10_000 < len(clip) < 500_000


def test_failed_first_up_leaves_no_env_file_so_a_corrected_retry_initialises(stack, monkeypatch, tmp_path):
    monkeypatch.setattr(stack, "ENV_FILE", tmp_path / ".env.e2e")
    monkeypatch.delenv("TAILNET_IP", raising=False)
    monkeypatch.setattr(stack.shutil, "which", lambda name: None)
    with pytest.raises(SystemExit):
        stack.write_env()
    assert list(tmp_path.iterdir()) == []

    monkeypatch.setenv("TAILNET_IP", "100.64.0.1")
    stack.write_env()
    env = stack.parse_env((tmp_path / ".env.e2e").read_text())
    assert env["TAILNET_IP"] == "100.64.0.1" and len(env["IOS_BEARER_TOKEN"]) == 64
    assert oct((tmp_path / ".env.e2e").stat().st_mode & 0o777) == "0o600"
    assert [p.name for p in tmp_path.iterdir()] == [".env.e2e"]


def test_up_rewrites_an_empty_env_file_left_by_an_older_failed_run(stack, monkeypatch, tmp_path):
    env_file = tmp_path / ".env.e2e"
    env_file.write_text("")
    written = []
    monkeypatch.setattr(stack, "ENV_FILE", env_file)
    monkeypatch.setattr(stack, "write_env", lambda: written.append(True))
    monkeypatch.setattr(stack, "compose", lambda *args, **kw: None)
    monkeypatch.setattr(stack, "client", lambda *args: None)
    stack.cmd_up()
    assert written == [True]


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


def test_e2e_env_turns_the_llm_steps_on_because_the_fixture_answers_them(stack):
    env = stack.parse_env(stack.render_env(ENV_EXAMPLE.read_text(), "100.64.0.1"))
    assert {env[k] for k in ("LLM_VALIDATION_ENABLED", "LLM_CORRECTION_ENABLED", "FLUENCY_CHECK_ENABLED")} == {"true"}


def test_only_the_e2e_files_point_the_webapp_at_the_fixture_upstreams():
    prod = (SERVER_DIR / "docker-compose.yml").read_text()
    assert "upstreams" not in prod
    assert "OLLAMA_BASE_URL=http://upstreams:11434" in ENV_EXAMPLE.read_text()


def test_session_client_saves_the_final_status_without_the_upload_clock():
    client = _load("e2e_client", SERVER_DIR / "e2e" / "e2e_client.py")
    first = client.canonical_status({"session_id": "s", "state": "done", "received_at": "2026-01-01T10:00:00Z"})
    second = client.canonical_status({"state": "done", "received_at": "2026-01-02T11:30:00Z", "session_id": "s"})
    assert first == second and b"received_at" not in first


def test_upstreams_command_prints_the_recorded_json_and_rejects_unknown_views(stack, monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(stack, "ENV_FILE", tmp_path / ".env.e2e")
    (tmp_path / ".env.e2e").write_text("TAILNET_IP=100.64.0.1\n")
    asked = []
    monkeypatch.setattr(stack, "fixture_upstreams", lambda what: asked.append(what) or '[{"kind":"analysis"}]')
    stack.cmd_upstreams("documents")
    assert asked == ["documents"] and '"kind": "analysis"' in capsys.readouterr().out
    with pytest.raises(SystemExit):
        stack.cmd_upstreams("secrets")
    assert asked == ["documents"]


def test_fixture_upstreams_are_read_from_inside_the_container_through_compose(stack, monkeypatch):
    seen = []
    monkeypatch.setattr(stack, "compose_output", lambda *args: seen.append(args) or "[]")
    assert stack.fixture_upstreams("requests") == "[]"
    assert seen[0][:4] == ("exec", "-T", "upstreams", "python")
    assert seen[0][-1] == "http://127.0.0.1:9621/_fixture/requests"


class _FakeUpstreams:
    """Stands in for the stack: what `upstreams` would serve after each run."""

    def __init__(self, runs):
        self.runs = iter(runs)
        self.current = None

    def reset(self):
        self.current = next(self.runs)

    def fetch(self, what):
        return json.dumps(self.current[what])


def _repeat(stack, monkeypatch, tmp_path, runs):
    fake = _FakeUpstreams(runs)
    monkeypatch.setattr(stack, "ENV_FILE", tmp_path / ".env.e2e")
    (tmp_path / ".env.e2e").write_text("TAILNET_IP=100.64.0.1\n")
    monkeypatch.setattr(stack.tempfile, "mkdtemp", lambda prefix: str(tmp_path))
    monkeypatch.setattr(stack, "cmd_reset", fake.reset)
    monkeypatch.setattr(stack, "fixture_upstreams", fake.fetch)

    def session(*args):
        (tmp_path / args[args.index("--save") + 1].rsplit("/", 1)[-1]).write_text('{"state": "done"}\n')

    monkeypatch.setattr(stack, "client", lambda *args: session(*args[1:]))
    stack.cmd_repeat()


def _run(narrative="# Narrativ", probes=1):
    entry = {"service": "ollama", "method": "POST", "path": "/v1/chat/completions", "kind": "analysis",
             "fixture": "e2e-cast", "bytes": 1, "sha256": "ab"}
    probe = {**entry, "method": "GET", "path": "/api/tags", "kind": "probe", "fixture": None}
    return {
        "requests": [probe] * probes + [entry],
        "documents": {"diary:2026-03-04": {"file_source": "f", "sha256": "x", "text": narrative}},
    }


def test_repeat_passes_when_two_clean_runs_produce_the_same_bytes_whatever_the_probe_count(
    stack, monkeypatch, tmp_path, capsys
):
    _repeat(stack, monkeypatch, tmp_path, [_run(probes=2), _run(probes=5)])
    out = capsys.readouterr().out
    assert "byte-identical" in out
    assert "kind=analysis fixture=e2e-cast" in out and "/api/tags" in out


def test_repeat_fails_when_the_narrative_differs_between_runs(stack, monkeypatch, tmp_path):
    with pytest.raises(SystemExit) as failed:
        _repeat(stack, monkeypatch, tmp_path, [_run("# Eins"), _run("# Zwei")])
    assert "documents" in str(failed.value)


def test_repeat_fails_when_no_narrative_reached_lightrag(stack, monkeypatch, tmp_path):
    empty = {**_run(), "documents": {}}
    with pytest.raises(SystemExit) as failed:
        _repeat(stack, monkeypatch, tmp_path, [empty, empty])
    assert "no diary narrative" in str(failed.value)
