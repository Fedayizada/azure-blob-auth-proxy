import base64
import json

import pytest

from auth import AuthError, Principal, authorize_groups, parse_client_principal

ALLOWED_GROUP = "11111111-1111-1111-1111-111111111111"
OTHER_GROUP = "22222222-2222-2222-2222-222222222222"


def _encode(principal: dict) -> str:
    return base64.b64encode(json.dumps(principal).encode("utf-8")).decode("ascii")


def _principal_header(groups, oid="user-oid", name="user@example.com", extra=None):
    claims = [{"typ": "groups", "val": g} for g in groups]
    claims.append(
        {
            "typ": "http://schemas.microsoft.com/identity/claims/objectidentifier",
            "val": oid,
        }
    )
    claims.append({"typ": "preferred_username", "val": name})
    if extra:
        claims.extend(extra)
    return _encode({"auth_typ": "aad", "claims": claims})


def test_parse_returns_none_without_header():
    assert parse_client_principal(None) is None
    assert parse_client_principal("") is None


def test_parse_returns_none_for_garbage():
    assert parse_client_principal("not-base64-$$$") is None
    assert parse_client_principal(base64.b64encode(b"not json").decode()) is None


def test_parse_extracts_groups_oid_and_name():
    header = _principal_header([ALLOWED_GROUP, OTHER_GROUP])
    principal = parse_client_principal(header)
    assert principal is not None
    assert principal.groups == frozenset({ALLOWED_GROUP, OTHER_GROUP})
    assert principal.object_id == "user-oid"
    assert principal.name == "user@example.com"
    assert principal.overage is False


def test_parse_detects_overage():
    header = _principal_header(
        [], extra=[{"typ": "_claim_names", "val": '{"groups":"src1"}'}]
    )
    principal = parse_client_principal(header)
    assert principal is not None
    assert principal.overage is True


def test_authorize_allows_member():
    principal = Principal(
        object_id="x", name="x", groups=frozenset({ALLOWED_GROUP}), overage=False
    )
    assert authorize_groups(principal, {ALLOWED_GROUP}) is principal


def test_authorize_denies_non_member():
    principal = Principal(
        object_id="x", name="x", groups=frozenset({OTHER_GROUP}), overage=False
    )
    with pytest.raises(AuthError) as exc:
        authorize_groups(principal, {ALLOWED_GROUP})
    assert exc.value.status == 403


def test_authorize_rejects_unauthenticated():
    with pytest.raises(AuthError) as exc:
        authorize_groups(None, {ALLOWED_GROUP})
    assert exc.value.status == 401


def test_authorize_rejects_misconfiguration():
    principal = Principal("x", "x", frozenset({ALLOWED_GROUP}), False)
    with pytest.raises(AuthError) as exc:
        authorize_groups(principal, set())
    assert exc.value.status == 500


def test_authorize_overage_safe_denies():
    principal = Principal("x", "x", frozenset(), overage=True)
    with pytest.raises(AuthError) as exc:
        authorize_groups(principal, {ALLOWED_GROUP})
    assert exc.value.status == 403


def test_end_to_end_header_to_authorization():
    header = _principal_header([ALLOWED_GROUP])
    principal = parse_client_principal(header)
    assert authorize_groups(principal, {ALLOWED_GROUP}).object_id == "user-oid"
