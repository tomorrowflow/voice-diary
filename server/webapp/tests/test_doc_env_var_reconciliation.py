"""DOC-6: deploy env-var docs must reflect the current stack (Voxtral,
Whisper sidecar, no n8n), not S1-era framing that implies removal/addition
of pieces that landed long ago and already live in .env.example /
docker-compose.yml.
"""

import os
import re

REPO_ROOT = os.path.join(os.path.dirname(__file__), "..", "..", "..")
DEVELOPMENT_MD = os.path.join(REPO_ROOT, "DEVELOPMENT.md")
CLAUDE_MD = os.path.join(REPO_ROOT, "CLAUDE.md")
ENV_EXAMPLE = os.path.join(REPO_ROOT, "server", ".env.example")


def _read(path: str) -> str:
    with open(path) as f:
        return f.read()


def _env_example_var_names() -> set[str]:
    text = _read(ENV_EXAMPLE)
    return set(re.findall(r"^([A-Z][A-Z0-9_]*)=", text, re.MULTILINE))


def _deploy_section() -> str:
    text = _read(DEVELOPMENT_MD)
    start = text.index("### 4.4 Deploying the server")
    end = text.index("## 5. iOS track", start)
    return text[start:end]


def _server_stack_table() -> str:
    text = _read(CLAUDE_MD)
    start = text.index("## Server stack")
    end = text.index("## Target device", start)
    return text[start:end]


def test_deploy_docs_do_not_frame_stack_as_still_being_migrated():
    section = _deploy_section()
    assert "after n8n cleanup in S1" not in section
    assert "after S2" not in section


def test_claude_md_server_stack_does_not_call_whisper_newly_added():
    # The stack table describes the deployed system today, not the S1
    # migration plan; "added in S1" reads as still-pending work even
    # though the Whisper sidecar has been live since S1 landed.
    assert "added in S1" not in _server_stack_table()


def test_deploy_docs_list_voxtral_tts_vars_present_in_env_example():
    section = _deploy_section()
    env_vars = _env_example_var_names()
    assert "HF_TOKEN" in env_vars
    assert "VOXTRAL_BASE_URL" in env_vars
    # The Voxtral sidecar (in-stack, GPU) needs HF_TOKEN to pull gated
    # weights; the deploy walkthrough must call it out or first-time
    # setup silently fails to boot voxtral-engine.
    assert "HF_TOKEN" in section
