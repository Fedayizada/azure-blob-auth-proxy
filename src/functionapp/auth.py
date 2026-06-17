"""Identity parsing and Entra group authorization.

Easy Auth (App Service Authentication) validates the Entra login at the platform
edge and injects the validated identity into the ``X-MS-CLIENT-PRINCIPAL`` header
(base64-encoded JSON). This module turns that header into a typed Principal and
enforces that the caller belongs to an allowed Entra group.

Group object IDs only appear in the principal when the App Registration emits a
``groups`` claim. Configure it as "Groups assigned to the application"
(group_membership_claims = ApplicationGroup) so the claim never hits the Entra
"overage" limit (~200 groups) that would otherwise leave it empty.
"""
from __future__ import annotations

import base64
import binascii
import json
from dataclasses import dataclass
from typing import Iterable

_GROUP_CLAIM_TYPES = frozenset(
    {
        "groups",
        "http://schemas.microsoft.com/ws/2008/06/identity/claims/groups",
    }
)
_OID_CLAIM_TYPES = frozenset(
    {
        "http://schemas.microsoft.com/identity/claims/objectidentifier",
        "oid",
    }
)
_NAME_CLAIM_TYPES = frozenset(
    {
        "name",
        "preferred_username",
        "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name",
    }
)
# Presence of these claims means Entra moved the group list to Microsoft Graph
# instead of inlining it (group overage). The inline `groups` claim is then empty.
_OVERAGE_CLAIM_TYPES = frozenset({"_claim_names", "_claim_sources"})


@dataclass(frozen=True)
class Principal:
    """A validated caller identity extracted from the Easy Auth header."""

    object_id: str | None
    name: str | None
    groups: frozenset[str]
    overage: bool


class AuthError(Exception):
    """Raised when a request cannot be authenticated or authorized."""

    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


def parse_client_principal(header_value: str | None) -> Principal | None:
    """Decode the ``X-MS-CLIENT-PRINCIPAL`` header into a Principal.

    Returns ``None`` when the header is absent or unparseable, which the caller
    must treat as unauthenticated.
    """
    if not header_value:
        return None
    try:
        decoded = base64.b64decode(header_value).decode("utf-8")
        data = json.loads(decoded)
    except (binascii.Error, ValueError, UnicodeDecodeError):
        return None
    if not isinstance(data, dict):
        return None

    claims = data.get("claims") or []
    groups: set[str] = set()
    object_id: str | None = None
    name: str | None = data.get("name") or None
    overage = False

    for claim in claims:
        if not isinstance(claim, dict):
            continue
        typ = claim.get("typ")
        val = claim.get("val")
        if not typ or val is None:
            continue
        if typ in _GROUP_CLAIM_TYPES:
            groups.add(val)
        elif typ in _OID_CLAIM_TYPES and object_id is None:
            object_id = val
        elif typ in _NAME_CLAIM_TYPES and name is None:
            name = val
        elif typ in _OVERAGE_CLAIM_TYPES:
            overage = True

    return Principal(
        object_id=object_id,
        name=name,
        groups=frozenset(groups),
        overage=overage,
    )


def authorize_groups(
    principal: Principal | None, allowed_group_ids: Iterable[str]
) -> Principal:
    """Ensure the caller is in at least one allowed group; return the principal.

    Raises AuthError(401) when unauthenticated, AuthError(500) when the server is
    misconfigured with no allowed groups, and AuthError(403) when the caller is
    not a member (including the safe-deny path for group overage).
    """
    if principal is None:
        raise AuthError(401, "Unauthenticated: missing or invalid client principal.")

    allowed = frozenset(allowed_group_ids)
    if not allowed:
        raise AuthError(500, "Server misconfigured: no allowed groups are set.")

    if principal.groups & allowed:
        return principal

    if principal.overage:
        # Groups were not inlined (overage). We cannot confirm membership from the
        # token, so deny rather than guess. Fix by scoping the groups claim to
        # "Groups assigned to the application".
        raise AuthError(
            403, "Group membership could not be evaluated (claim overage)."
        )

    raise AuthError(403, "Forbidden: caller is not a member of an allowed group.")
