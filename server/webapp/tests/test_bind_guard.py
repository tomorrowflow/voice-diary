"""Tests for `bind_guard.check_tailnet_bind` (SEC-1).

Pure function, no FastAPI app / docker needed.
"""

from __future__ import annotations

import pytest

from bind_guard import BindGuardError, check_tailnet_bind, enforce_tailnet_bind


def test_missing_tailnet_ip_raises():
    with pytest.raises(BindGuardError, match="TAILNET_IP is not set"):
        check_tailnet_bind(None)


def test_malformed_ip_raises():
    with pytest.raises(BindGuardError, match="not a valid IP address"):
        check_tailnet_bind("not-an-ip")


def test_all_interfaces_raises():
    with pytest.raises(BindGuardError, match="outside Tailscale's CGNAT range"):
        check_tailnet_bind("0.0.0.0")


def test_public_ip_raises():
    with pytest.raises(BindGuardError, match="outside Tailscale's CGNAT range"):
        check_tailnet_bind("203.0.113.5")


def test_valid_tailnet_ip_passes():
    check_tailnet_bind("100.101.102.103")  # does not raise


def test_enforce_logs_reason_before_raising(monkeypatch, caplog):
    monkeypatch.delenv("TAILNET_IP", raising=False)
    with caplog.at_level("ERROR"):
        with pytest.raises(BindGuardError):
            enforce_tailnet_bind()
    assert "Refusing to start" in caplog.text
    assert "TAILNET_IP is not set" in caplog.text
