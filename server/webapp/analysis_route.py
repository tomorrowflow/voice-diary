"""Analysis route: where the main narrative analysis call goes (BAR-01, ADR 0004).

`ANALYSIS_ROUTE=local` (the default) keeps the call on Ollama, as it always
was. `ANALYSIS_ROUTE=blindfold` posts it, in the same OpenAI chat-completions
shape, to `BLINDFOLD_BASE_URL` with `BLINDFOLD_ANALYSIS_MODEL`. Only
`document_processor.analyze_transcript` follows the route; the context summary
and every other LLM call stay on local Ollama.

The settings are read from the environment once at start-up (`configure`, from
main.py's lifespan) and are not editable at runtime. An invalid or incomplete
configuration refuses to start; it never falls back to local.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Mapping
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)

LOCAL = "local"
BLINDFOLD = "blindfold"
_ROUTES = (LOCAL, BLINDFOLD)


class AnalysisRouteError(RuntimeError):
    """Raised when the analysis route settings are invalid or incomplete."""


@dataclass(frozen=True)
class AnalysisRoute:
    """The validated route. The `blindfold_*` fields are only set when routed;
    `blindfold_timeout` of `None` means "use the local analysis timeout"."""

    name: str = LOCAL
    blindfold_base_url: str | None = None
    blindfold_model: str | None = None
    blindfold_timeout: float | None = None
    # Never logged: kept out of the dataclass repr as well.
    blindfold_api_key: str | None = field(default=None, repr=False)

    @property
    def is_blindfold(self) -> bool:
        return self.name == BLINDFOLD


def from_env(env: Mapping[str, str] | None = None) -> AnalysisRoute:
    """Validate the route settings in `env` (default: the process environment)."""
    env = os.environ if env is None else env

    def get(name: str) -> str:
        return (env.get(name) or "").strip()

    name = get("ANALYSIS_ROUTE") or LOCAL
    if name not in _ROUTES:
        raise AnalysisRouteError(
            f"ANALYSIS_ROUTE={name!r} is not valid; use 'local' or 'blindfold'."
        )
    if name == LOCAL:
        return AnalysisRoute()

    base_url = get("BLINDFOLD_BASE_URL").rstrip("/")
    if not base_url:
        raise AnalysisRouteError(
            "BLINDFOLD_BASE_URL is required when ANALYSIS_ROUTE=blindfold."
        )
    model = get("BLINDFOLD_ANALYSIS_MODEL")
    if not model:
        raise AnalysisRouteError(
            "BLINDFOLD_ANALYSIS_MODEL is required when ANALYSIS_ROUTE=blindfold."
        )

    timeout: float | None = None
    raw_timeout = get("BLINDFOLD_ANALYSIS_TIMEOUT")
    if raw_timeout:
        try:
            timeout = float(raw_timeout)
        except ValueError:
            timeout = None
        if timeout is None or not timeout > 0:
            raise AnalysisRouteError(
                f"BLINDFOLD_ANALYSIS_TIMEOUT={raw_timeout!r} must be a positive number of seconds."
            )

    return AnalysisRoute(
        name=BLINDFOLD,
        blindfold_base_url=base_url,
        blindfold_model=model,
        blindfold_timeout=timeout,
        blindfold_api_key=get("BLINDFOLD_API_KEY") or None,
    )


def recorded_route(metadata: Mapping[str, object] | None) -> str:
    """The route recorded in a saved narrative's metadata (`analysis_route`,
    BAR-04). A row written before the key existed was analysed locally."""
    return str((metadata or {}).get("analysis_route") or LOCAL)


_active: AnalysisRoute | None = None


def configure() -> AnalysisRoute:
    """Call once at process startup (main.py's lifespan). Validates the
    environment, makes the result the active route, and logs one WARNING when
    analysis egress is enabled. Logs the reason at ERROR before re-raising, so
    a bad configuration fails loudly instead of quietly running locally."""
    global _active
    try:
        route = from_env()
    except AnalysisRouteError as exc:
        logger.error("Refusing to start: %s", exc)
        raise
    _active = route
    if route.is_blindfold:
        logger.warning(
            "Analysis egress is ENABLED: the main narrative analysis is sent to "
            "Blindfold at %s (model: %s)",
            route.blindfold_base_url, route.blindfold_model,
        )
    return route


def current() -> AnalysisRoute:
    """The route in force. Read at call time, so a retry or sweep follows the
    route it runs under. Outside the app (no `configure`) it is read from the
    environment on first use."""
    global _active
    if _active is None:
        _active = from_env()
    return _active
