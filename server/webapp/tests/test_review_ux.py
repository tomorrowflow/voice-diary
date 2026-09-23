"""UX-12: empty states + save feedback in the HTMX review UI.

review.html/app.js are rendered client-side (vanilla JS, no template test
harness for that layer exists in this repo), so these tests check the two
things pytest *can* verify without a browser:

  - the server-rendered template ships the markup/hooks the JS needs
    (empty-state containers, the toast host, focus-visible affordances)
  - static/app.js contains the behavior that drives those hooks

Run: docker compose run --rm webapp pytest webapp/tests/test_review_ux.py
"""

from __future__ import annotations

from pathlib import Path

from fastapi.templating import Jinja2Templates
from starlette.requests import Request

WEBAPP_DIR = Path(__file__).resolve().parent.parent


def _render_review_html() -> str:
    templates = Jinja2Templates(directory=str(WEBAPP_DIR / "templates"))
    request = Request({"type": "http", "method": "GET", "path": "/", "headers": []})
    ctx = {
        "request": request,
        "transcript": {
            "id": 1,
            "filename": "2026-07-04.m4a",
            "date": "2026-07-04",
            "author": "Florian Wolf",
            "status": "reviewed",
        },
        "entities_json": "[]",
        "raw_text": "hello world",
        "person_count": 3,
        "term_count": 5,
        "llm_enabled": False,
        "applied_corrections": "[]",
        "needs_processing": False,
    }
    return templates.TemplateResponse(request, "review.html", ctx).body.decode()


def _app_js() -> str:
    return (WEBAPP_DIR / "static" / "app.js").read_text()


# --- empty states -----------------------------------------------------


def test_entity_list_has_empty_state_container():
    html = _render_review_html()
    assert 'id="entity-list-empty"' in html


def test_render_entity_list_toggles_empty_state():
    js = _app_js()
    render_fn = js.split("function renderEntityList()")[1].split("\nfunction ")[0]
    assert "entity-list-empty" in render_fn
