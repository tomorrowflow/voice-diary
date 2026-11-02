"""Isolated e2e server stack (Compose project `vd-e2e`), next to the prod stack.

    up       build and start the stack; writes .env.e2e on first run
    check    /health and the e2e bearer, over the tailnet IP
    session  post a fixture session bundle and poll it to its end state
    reset    drop and reseed the e2e DB (fixed fictional cast), clear Qdrant
             and stored session bundles, restart the fixture upstreams
    upstreams  print what the fixture upstreams recorded since the last reset:
             `requests` (every endpoint hit, with kind, fixture and body digest)
             or `documents` (what LightRAG was given, the day narrative among it)
    repeat   reset, run the fixture session, keep its final status, narrative
             and request log; do it twice and fail unless the two are
             byte-identical
    down     stop the stack and delete its containers, network and volumes

Usage (stdlib only; run from anywhere):

    python3 scripts/e2e_stack.py up|check|session [client args]|reset|down
    python3 scripts/e2e_stack.py upstreams [requests|documents]
    python3 scripts/e2e_stack.py repeat [client args]

Environment:
    TAILNET_IP   used only when .env.e2e does not exist yet; default is
                 `tailscale ip -4`

Safety: every Compose call is `-p vd-e2e` with `--env-file .env.e2e`, so the
prod `.env`, `data/msal_cache.bin` and the prod volumes are never read or
touched, and `down -v` can only delete this project's volumes.
"""

import collections
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SERVER_DIR = Path(__file__).resolve().parent.parent
PROJECT = "vd-e2e"
ENV_FILE = SERVER_DIR / ".env.e2e"
ENV_EXAMPLE = SERVER_DIR / ".env.e2e.example"
CLIENT = SERVER_DIR / "e2e" / "e2e_client.py"
PORT = 8100
REPEAT_SESSION_ID = "e2e-repeat"
FIXTURE_ENDPOINTS = ("requests", "documents")

# Compose's own interpolation prefers the shell over --env-file. Drop anything
# a prod session may have exported so only .env.e2e feeds this project.
SCRUBBED_ENV = (
    "TAILNET_IP", "POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB", "IOS_BEARER_TOKEN",
    "WHISPER_URL", "WHISPER_MODEL", "WHISPER_IMAGE_TAG", "WHISPER_ENGINE", "E2E_WHISPER_MODEL",
    "VOXTRAL_BASE_URL", "VOXTRAL_MODEL", "VOXTRAL_TIMEOUT_SECONDS", "HF_TOKEN",
    "HARVEST_ACCESS_TOKEN", "HARVEST_ACCOUNT_ID", "HARVEST_USER_ID",
)

RESET_SQL = r"""
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
  -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\" WITH (FORCE)" \
  -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\"" &&
psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -f /docker-entrypoint-initdb.d/01-schema.sql \
  -f /docker-entrypoint-initdb.d/02-seed.sql
"""

# Run inside the webapp image, which has httpx. The webapp recreates its
# collections on start.
RESET_QDRANT = """
import httpx

base = "http://qdrant:6333"
for c in httpx.get(base + "/collections").json()["result"]["collections"]:
    httpx.delete(f"{base}/collections/{c['name']}").raise_for_status()
"""


def compose_command(args: list[str]) -> list[str]:
    return [
        "docker", "compose", "-p", PROJECT, "--env-file", str(ENV_FILE),
        "--project-directory", str(SERVER_DIR),
        "-f", str(SERVER_DIR / "docker-compose.yml"),
        "-f", str(SERVER_DIR / "docker-compose.e2e.yml"),
        *args,
    ]


def scrubbed_env() -> dict[str, str]:
    return {k: v for k, v in os.environ.items() if k not in SCRUBBED_ENV}


def compose(*args: str, stdin: str | None = None) -> None:
    subprocess.run(compose_command(list(args)), check=True, env=scrubbed_env(), input=stdin, text=True)


def compose_output(*args: str) -> str:
    done = subprocess.run(compose_command(list(args)), check=True, env=scrubbed_env(), capture_output=True, text=True)
    return done.stdout


def fixture_upstreams(what: str) -> str:
    """What the `upstreams` service recorded, as the JSON it served. Its ports
    are not published, so the request is made from inside its container."""
    fetch = "import sys, urllib.request; sys.stdout.write(urllib.request.urlopen(sys.argv[1], timeout=10).read().decode())"
    return compose_output(
        "exec", "-T", "upstreams", "python", "-c", fetch, f"http://127.0.0.1:9621/_fixture/{what}"
    )


def parse_env(text: str) -> dict[str, str]:
    values = {}
    for line in text.splitlines():
        match = re.match(r"([A-Z][A-Z0-9_]*)=(.*)$", line)
        if match:
            values[match.group(1)] = match.group(2)
    return values


def env_value(key: str) -> str:
    return parse_env(ENV_FILE.read_text())[key]


def render_env(example: str, tailnet_ip: str) -> str:
    """The example without comments, with the placeholders filled: the tailnet
    IP and two fresh secrets, so no value is shared with the prod `.env`."""
    fills = {
        "TAILNET_IP": tailnet_ip,
        "POSTGRES_PASSWORD": secrets.token_hex(32),
        "IOS_BEARER_TOKEN": secrets.token_hex(32),
    }
    lines = []
    for line in example.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key = line.split("=", 1)[0]
        lines.append(f"{key}={fills[key]}" if key in fills else line)
    return "\n".join(lines) + "\n"


def tailnet_ip() -> str:
    ip = os.environ.get("TAILNET_IP", "").strip()
    if not ip and shutil.which("tailscale"):
        out = subprocess.run(["tailscale", "ip", "-4"], check=True, capture_output=True, text=True).stdout
        ip = out.split()[0] if out.split() else ""
    if not ip:
        sys.exit("! Set TAILNET_IP to this host's Tailscale IPv4 (tailscale ip -4)")
    return ip


def write_env() -> None:
    """Write .env.e2e only once everything it needs is known, and put it in
    place atomically, so a failed first `up` never leaves a file that blocks a
    corrected retry."""
    content = render_env(ENV_EXAMPLE.read_text(), tailnet_ip())
    partial = ENV_FILE.with_name(ENV_FILE.name + ".partial")
    partial.unlink(missing_ok=True)
    fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(content)
    os.replace(partial, ENV_FILE)
    print(f"✓ Wrote {ENV_FILE.name} (own bearer and Postgres password; prod .env untouched)")


def require_env() -> None:
    if not ENV_FILE.exists() or ENV_FILE.stat().st_size == 0:
        sys.exit(f"! {ENV_FILE.name} not found; run 'e2e_stack.py up' first")


def client(*args: str) -> None:
    env = {
        **os.environ,
        "BASE_URL": f"http://{env_value('TAILNET_IP')}:{PORT}",
        "IOS_BEARER_TOKEN": env_value("IOS_BEARER_TOKEN"),
    }
    subprocess.run([sys.executable, "-I", str(CLIENT), *args], check=True, env=env)


def cmd_up() -> None:
    # An empty file is what an older failed first `up` left behind; it holds
    # nothing worth keeping.
    if not ENV_FILE.exists() or ENV_FILE.stat().st_size == 0:
        write_env()
    compose("pull", "whisper")
    compose("up", "-d", "--build", "--wait", "webapp")
    client("ready")
    print(f"✓ vd-e2e up on http://<TAILNET_IP>:{PORT}")


def cmd_check() -> None:
    require_env()
    client("health")


def cmd_session(*args: str) -> None:
    require_env()
    client("session", *args)


def cmd_reset() -> None:
    require_env()
    compose("stop", "webapp", "upstreams")
    compose("up", "-d", "--wait", "postgres", "qdrant")
    # Drop and recreate from the same files postgres runs on first init.
    compose("exec", "-T", "-e", "PGOPTIONS=-c client_min_messages=warning", "postgres", "sh", "-c", RESET_SQL)
    # Qdrant collections and stored bundles hold session state too.
    compose("run", "--rm", "--no-deps", "-T", "--entrypoint", "python", "webapp", "-", stdin=RESET_QDRANT)
    compose("run", "--rm", "--no-deps", "-T", "--entrypoint", "sh", "webapp", "-c", "rm -rf /data/sessions")
    compose("up", "-d", "--wait", "upstreams", "webapp")
    print("✓ vd-e2e reset to the fixture cast")


def cmd_upstreams(what: str = "requests") -> None:
    require_env()
    if what not in FIXTURE_ENDPOINTS:
        sys.exit(f"! usage: e2e_stack.py upstreams {'|'.join(FIXTURE_ENDPOINTS)}")
    print(json.dumps(json.loads(fixture_upstreams(what)), indent=2, ensure_ascii=False))


def summarise_requests(log: list[dict]) -> list[str]:
    """One line per distinct endpoint hit, with its fixture and call count."""
    hits = collections.Counter((e["service"], e["method"], e["path"], e["kind"], e["fixture"]) for e in log)
    return [f"  {n:>3}x {service:<8} {method:<6} {path:<28} kind={kind} fixture={fixture}"
            for (service, method, path, kind, fixture), n in sorted(hits.items(), key=lambda kv: str(kv[0]))]


def cmd_repeat(*client_args: str) -> None:
    """Run the fixture session twice from a clean reset each time and compare
    what comes out: the final status, the documents LightRAG was given (the
    day narrative among them) and the upstream request log without health
    probes. Any difference fails the command."""
    require_env()
    out = Path(tempfile.mkdtemp(prefix="vd-e2e-repeat-"))
    for run in (1, 2):
        cmd_reset()
        client("session", "--session-id", REPEAT_SESSION_ID, "--expect-done",
               "--save", str(out / f"run{run}-status.json"), *client_args)
        for what in FIXTURE_ENDPOINTS:
            (out / f"run{run}-{what}.json").write_text(fixture_upstreams(what))
        # Health probes arrive whenever Compose and the webapp poll; how many
        # land is timing, not behaviour, so the compared log leaves them out.
        log = json.loads((out / f"run{run}-requests.json").read_text())
        (out / f"run{run}-pipeline-requests.json").write_text(
            json.dumps([e for e in log if e["kind"] != "probe"], indent=2))
    narratives = [
        {i: d for i, d in json.loads((out / f"run{run}-documents.json").read_text()).items() if i.startswith("diary:")}
        for run in (1, 2)
    ]
    if not narratives[0]:
        sys.exit(f"! no diary narrative reached LightRAG in run 1 (files in {out})")
    print(f"upstream requests, run 1 (files in {out}):")
    print("\n".join(summarise_requests(json.loads((out / "run1-requests.json").read_text()))))
    different = []
    for name in ("status", "documents", "pipeline-requests"):
        a, b = [(out / f"run{run}-{name}.json").read_bytes() for run in (1, 2)]
        digest = hashlib.sha256(a).hexdigest()[:16]
        print(f"{name:<17} run1 {digest}  run2 {hashlib.sha256(b).hexdigest()[:16]}  "
              f"{'identical' if a == b else 'DIFFERENT'}")
        if a != b:
            different.append(name)
    for doc_id in narratives[0]:
        print(f"narrative {doc_id}: {len(narratives[0][doc_id]['text'])} chars, sha256 {narratives[0][doc_id]['sha256'][:16]}")
    if different:
        sys.exit(f"! runs differ in: {', '.join(different)} (diff {out}/run1-* {out}/run2-*)")
    print("✓ two runs from a clean reset are byte-identical")


def cmd_down() -> None:
    require_env()
    compose("down", "-v", "--remove-orphans")
    print("✓ vd-e2e removed (containers, network, volumes)")


COMMANDS = {
    "up": cmd_up,
    "check": cmd_check,
    "session": cmd_session,
    "reset": cmd_reset,
    "upstreams": cmd_upstreams,
    "repeat": cmd_repeat,
    "down": cmd_down,
}


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in COMMANDS:
        print("usage: e2e_stack.py up|check|session|reset|upstreams|repeat|down", file=sys.stderr)
        return 2
    try:
        COMMANDS[argv[0]](*argv[1:])
    except subprocess.CalledProcessError as exc:
        return exc.returncode or 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
