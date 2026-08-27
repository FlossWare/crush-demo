"""Discover provider API-key credentials from the process environment.

Convention:
    PROVIDER_API_KEY
    PROVIDER_API_KEY_ACCOUNT

The account suffix is optional. Values are never returned by this module.
Only variable names and normalized metadata are exposed.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass


_KEY_RE = re.compile(r"^(?P<provider>[A-Z0-9]+)_API_KEY(?:_(?P<account>[A-Z0-9][A-Z0-9_]*))?$")


@dataclass(frozen=True)
class CredentialRef:
    provider: str
    account: str
    env_var: str


def discover_credentials(environ: dict[str, str] | None = None) -> list[CredentialRef]:
    """Return configured API-key references without exposing secret values."""
    env = os.environ if environ is None else environ
    found: list[CredentialRef] = []
    for name, value in env.items():
        if not value:
            continue
        match = _KEY_RE.match(name)
        if not match:
            continue
        found.append(
            CredentialRef(
                provider=match.group("provider").lower(),
                account=(match.group("account") or "default").lower(),
                env_var=name,
            )
        )
    return sorted(found, key=lambda c: (c.provider, c.account, c.env_var))
