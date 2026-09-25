"""SRV-A11: n8n was removed from the pipeline in S1; no reference should remain.

Guards against regressions re-introducing n8n mentions in main.py (e.g. via a
copy-pasted docstring or comment referring to the old n8n forward).
"""

from __future__ import annotations

from pathlib import Path

MAIN_PY = Path(__file__).resolve().parent.parent / "main.py"


def test_main_py_has_no_n8n_reference():
    source = MAIN_PY.read_text()
    assert "n8n" not in source.lower()
