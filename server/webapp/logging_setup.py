"""Structured JSON logging + per-request correlation IDs.

- Every log line is a single JSON object on stdout (Docker captures it).
- A request-ID middleware generates a UUID per incoming HTTP request and
  threads it into log records via `contextvars`. Long-running session
  pipelines re-use the same ID by reading + setting `bind_session_id()`.
- The formatter strips any `Authorization` header from `extra` payloads,
  defending against accidental token leakage.
- Hand-rolled formatter — no third-party logging dep, keeps the image lean.
"""

from __future__ import annotations

import contextvars
import json
import logging
import time
import uuid
from typing import Any, Awaitable, Callable

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response


# --- contextvar plumbing --------------------------------------------------


request_id_var: contextvars.ContextVar[str] = contextvars.ContextVar(
    "request_id", default=""
)
session_id_var: contextvars.ContextVar[str] = contextvars.ContextVar(
    "session_id", default=""
)


def bind_session_id(value: str | None) -> None:
    session_id_var.set(value or "")


# --- formatter ------------------------------------------------------------


_REDACTED = "***redacted***"
_SENSITIVE_KEYS = frozenset({"authorization", "auth", "token", "bearer"})


def _safe_extra(extra: dict[str, Any]) -> dict[str, Any]:
    return {
        k: (_REDACTED if k.lower() in _SENSITIVE_KEYS else v)
        for k, v in extra.items()
    }


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        rid = request_id_var.get()
        sid = session_id_var.get()
        if rid:
            payload["request_id"] = rid
        if sid:
            payload["session_id"] = sid
        # Pull through any user-supplied extras safely.
        for key, value in record.__dict__.items():
            if key in (
                "args", "asctime", "created", "exc_info", "exc_text",
                "filename", "funcName", "levelname", "levelno", "lineno",
                "module", "msecs", "msg", "name", "pathname", "process",
                "processName", "relativeCreated", "stack_info", "thread",
                "threadName", "message", "taskName",
            ):
                continue
            payload[key] = _REDACTED if key.lower() in _SENSITIVE_KEYS else value
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str, ensure_ascii=False)


def configure_logging() -> None:
    """Replace the root handler with a single JSON-formatting StreamHandler."""
    root = logging.getLogger()
    for h in list(root.handlers):
        root.removeHandler(h)
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())
    root.addHandler(handler)
    root.setLevel(logging.INFO)
    # Quieten chatty third parties by default.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)


# --- middleware -----------------------------------------------------------


class CorrelationIdMiddleware(BaseHTTPMiddleware):
    """Assigns a UUID4 to every request and logs a single completion line."""

    HEADER = "X-Request-ID"

    async def dispatch(
        self,
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        rid = request.headers.get(self.HEADER) or uuid.uuid4().hex
        token = request_id_var.set(rid)
        # Reset session_id at the start of each request.
        session_token = session_id_var.set("")
        started = time.monotonic()
        try:
            response = await call_next(request)
        except Exception:
            logging.getLogger(__name__).exception(
                "request_failed",
                extra={
                    "method": request.method,
                    "path": request.url.path,
                    "duration_ms": int((time.monotonic() - started) * 1000),
                },
            )
            raise
        finally:
            duration_ms = int((time.monotonic() - started) * 1000)
            try:
                response.headers[self.HEADER] = rid
            except Exception:  # pragma: no cover — defensive
                pass
            logging.getLogger("voice_diary.request").info(
                "request",
                extra={
                    "method": request.method,
                    "path": request.url.path,
                    "status_code": getattr(locals().get("response"), "status_code", 0),
                    "duration_ms": duration_ms,
                },
            )
            request_id_var.reset(token)
            session_id_var.reset(session_token)
        return response
