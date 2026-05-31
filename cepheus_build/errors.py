"""Shared exception types for the Cepheus build toolkit."""

from __future__ import annotations


class BuildError(RuntimeError):
    """Raised when config or command execution fails."""
