"""Isolated e2e server stack (Compose project `vd-e2e`), next to the prod stack.

    up       build and start the stack; writes .env.e2e on first run
    check    /health and the e2e bearer, over the tailnet IP
    session  post a fixture session bundle and poll it to its end state
    reset    drop and reseed the e2e DB (fixed fictional cast), clear Qdrant
             and stored session bundles, restart the fixture upstreams
    down     stop the stack and delete its containers, network and volumes

Usage (stdlib only; run from anywhere):

    python3 scripts/e2e_stack.py up|check|session [client args]|reset|down

Environment:
    TAILNET_IP   used only when .env.e2e does not exist yet; default is
                 `tailscale ip -4`

Safety: every Compose call is `-p vd-e2e` with `--env-file .env.e2e`, so the
prod `.env`, `data/msal_cache.bin` and the prod volumes are never read or
touched, and `down -v` can only delete this project's volumes.
"""

import os
import re
import secrets
import shutil
import subprocess
import sys
from pathlib import Path

SERVER_DIR = Path(__file__).resolve().parent.parent
PROJECT = "vd-e2e"
ENV_FILE = SERVER_DIR / ".env.e2e"
ENV_EXAMPLE = SERVER_DIR / ".env.e2e.example"
CLIENT = SERVER_DIR / "e2e" / "e2e_client.py"
PORT = 8100

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


def compose(*args: str, stdin: str | None = None) -> None:
    env = {k: v for k, v in os.environ.items() if k not in SCRUBBED_ENV}
    subprocess.run(compose_command(list(args)), check=True, env=env, input=stdin, text=True)


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
    fd = os.open(ENV_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(render_env(ENV_EXAMPLE.read_text(), tailnet_ip()))
    print(f"✓ Wrote {ENV_FILE.name} (own bearer and Postgres password; prod .env untouched)")


def require_env() -> None:
    if not ENV_FILE.exists():
        sys.exit(f"! {ENV_FILE.name} not found; run 'e2e_stack.py up' first")


def client(*args: str) -> None:
    env = {
        **os.environ,
        "BASE_URL": f"http://{env_value('TAILNET_IP')}:{PORT}",
        "IOS_BEARER_TOKEN": env_value("IOS_BEARER_TOKEN"),
    }
    subprocess.run([sys.executable, "-I", str(CLIENT), *args], check=True, env=env)


def cmd_up() -> None:
    if not ENV_FILE.exists():
        write_env()
    compose("up", "-d", "--build", "--wait", "webapp")
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


def cmd_down() -> None:
    require_env()
    compose("down", "-v", "--remove-orphans")
    print("✓ vd-e2e removed (containers, network, volumes)")


COMMANDS = {
    "up": cmd_up,
    "check": cmd_check,
    "session": cmd_session,
    "reset": cmd_reset,
    "down": cmd_down,
}


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in COMMANDS:
        print("usage: e2e_stack.py up|check|session|reset|down", file=sys.stderr)
        return 2
    try:
        COMMANDS[argv[0]](*argv[1:])
    except subprocess.CalledProcessError as exc:
        return exc.returncode or 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
