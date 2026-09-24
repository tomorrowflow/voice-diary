"""Startup guard: refuse to serve unless TAILNET_IP is a real tailnet address.

Constraint #6 (CLAUDE.md): "Tailscale, not public endpoints. The server must
never be publicly reachable." Until now that was enforced by nothing but the
docker-compose port publish — an omitted or misconfigured `${TAILNET_IP}`
substitution there silently falls back to binding all interfaces, exposing
every route regardless of bearer-token auth (SEC-1 / SEC-2).

`enforce_tailnet_bind`, called from main.py's lifespan before anything else
initializes, turns that assumption from documentation into a fail-closed
startup check: the process refuses to come up unless `TAILNET_IP` resolves to
an address in Tailscale's CGNAT range (100.64.0.0/10).
"""

from __future__ import annotations

import ipaddress
import logging
import os

logger = logging.getLogger(__name__)

_TAILSCALE_CGNAT = ipaddress.ip_network("100.64.0.0/10")


class BindGuardError(RuntimeError):
    """Raised when the effective bind/exposure violates the tailnet-only boundary."""


def check_tailnet_bind(tailnet_ip: str | None) -> None:
    tailnet_ip = (tailnet_ip or "").strip()
    if not tailnet_ip:
        raise BindGuardError(
            "TAILNET_IP is not set. Refusing to start: without it, "
            "docker-compose.yml's webapp port publish falls back to binding "
            "all interfaces, exposing every endpoint beyond the tailnet. Set "
            "TAILNET_IP in server/.env to this host's Tailscale IPv4 address."
        )
    try:
        addr = ipaddress.ip_address(tailnet_ip)
    except ValueError as exc:
        raise BindGuardError(
            f"TAILNET_IP={tailnet_ip!r} is not a valid IP address."
        ) from exc
    if addr not in _TAILSCALE_CGNAT:
        raise BindGuardError(
            f"TAILNET_IP={tailnet_ip} is outside Tailscale's CGNAT range "
            "(100.64.0.0/10). Refusing to start — this does not look like a "
            "tailnet address, and binding it would risk exposing every "
            "endpoint beyond the tailnet."
        )


def enforce_tailnet_bind() -> None:
    """Call once at process startup (main.py's lifespan). Logs the reason at
    ERROR before re-raising, so a misconfigured deploy fails loudly instead of
    silently serving on 0.0.0.0."""
    tailnet_ip = os.getenv("TAILNET_IP")
    try:
        check_tailnet_bind(tailnet_ip)
    except BindGuardError as exc:
        logger.error("Refusing to start: %s", exc)
        raise
    logger.info("TAILNET_IP = %s (bind guard OK)", tailnet_ip)
