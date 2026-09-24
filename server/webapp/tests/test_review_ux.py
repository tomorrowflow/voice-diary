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

import re
from pathlib import Path

from fastapi.templating import Jinja2Templates
from starlette.requests import Request

WEBAPP_DIR = Path(__file__).resolve().parent.parent

# literal px values in a CSS declaration (var(--*) references don't match)
_LITERAL_PX = re.compile(r"(?:^|[:\s])(?:-?\d+\.?\d*)px")


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


def test_correction_summary_has_no_loading_placeholder():
    # Everything correction-summary shows is server-rendered (render() runs at
    # script parse), so a "Loading..." placeholder is dead text, never a state.
    html = _render_review_html()
    summary = html.split('id="correction-summary"')[1].split("</span>")[0]
    assert "Loading" not in summary


# --- save / add confirmation -------------------------------------------


def test_review_html_has_toast_host():
    html = _render_review_html()
    assert 'id="toast"' in html


def test_app_js_defines_show_toast():
    js = _app_js()
    assert "function showToast(" in js


def test_save_draft_shows_confirmation_toast():
    js = _app_js()
    save_fn = js.split("async function saveDraft()")[1].split("\nasync function")[0]
    assert "showToast(" in save_fn


# --- undo after addManualEntity -----------------------------------------


def test_add_manual_entity_shows_confirmation_toast():
    js = _app_js()
    add_fn = js.split("function addManualEntity(type)")[1].split("\nfunction ")[0]
    assert "showToast(" in add_fn


def test_add_manual_entity_offers_undo():
    js = _app_js()
    add_fn = js.split("function addManualEntity(type)")[1].split("\nfunction ")[0]
    assert "undoLastManualEntity" in add_fn
    assert "function undoLastManualEntity(" in js


# --- entity-type popup keyboard affordance -------------------------------


def test_selection_popup_focuses_first_type_button_when_shown():
    js = _app_js()
    assert "focusFirstEntityTypeButton" in js


def test_selection_popup_types_listen_for_escape_and_arrow_keys():
    js = _app_js()
    assert "function selectionPopupTypeKeydown(" in js
    handler = js.split("function selectionPopupTypeKeydown(")[1].split("\nfunction ")[0]
    assert "Escape" in handler
    assert "ArrowRight" in handler and "ArrowLeft" in handler


def test_selection_popup_types_have_focus_visible_style():
    css = (WEBAPP_DIR / "static" / "style.css").read_text()
    assert ".selection-popup-types button:focus-visible" in css


# --- design tokens in the new UX-12 components ---------------------------


def _css_rule(css: str, selector: str) -> str:
    start = css.index(selector) + len(selector)
    return css[start : css.index("}", start)]


def test_ux12_components_do_not_hard_code_font_size_or_spacing():
    # CLAUDE.md hard rule 1: colours, spacing, radius and font sizes in
    # feature CSS go through var(--*), never literals. (Border hairline
    # widths have no token and are out of scope.)
    css = (WEBAPP_DIR / "static" / "style.css").read_text()
    for selector in (".toast-action ", ".entity-list-empty "):
        rule = _css_rule(css, selector)
        for prop in ("font-size", "margin", "padding"):
            for value in re.findall(prop + r":([^;]+);", rule):
                assert not _LITERAL_PX.search(value), (selector, prop)


def test_toast_action_only_clickable_while_toast_visible():
    # .toast is pointer-events:none; the Undo button must not stay an
    # invisible click target over the footer once the toast fades out.
    css = (WEBAPP_DIR / "static" / "style.css").read_text()
    assert "pointer-events" not in _css_rule(css, ".toast-action {")
    assert ".toast.visible .toast-action { pointer-events: auto; }" in css
