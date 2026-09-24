"""Guards against a hardcoded Postgres password creeping back into
docker-compose.yml. SEC-4: mitigated today only by no host port publish
on the postgres service; becomes load-bearing the moment someone maps
5432 for debugging, so the credential must come from a generated
POSTGRES_PASSWORD in .env instead of the literal "diary".
"""

import os

COMPOSE_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..", "docker-compose.yml"
)
ENV_EXAMPLE_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..", ".env.example"
)


def _read_compose() -> str:
    with open(COMPOSE_PATH) as f:
        return f.read()


def _read_env_example() -> str:
    with open(ENV_EXAMPLE_PATH) as f:
        return f.read()


def test_postgres_password_is_not_hardcoded():
    text = _read_compose()
    assert "POSTGRES_PASSWORD: diary" not in text
    assert "diary:diary" not in text


def test_postgres_password_has_no_silent_default():
    # `${POSTGRES_PASSWORD:-something}` would silently fall back to a
    # guessable value if .env is missing the var; `${POSTGRES_PASSWORD:?...}`
    # makes `docker compose up` fail loudly instead.
    text = _read_compose()
    assert "${POSTGRES_PASSWORD:?" in text
    assert "${POSTGRES_PASSWORD:-" not in text


def test_env_example_documents_generated_password():
    text = _read_env_example()
    assert "POSTGRES_PASSWORD=" in text
    assert "POSTGRES_PASSWORD=diary" not in text
    assert "postgresql://diary:diary@" not in text
    assert "openssl rand" in text
