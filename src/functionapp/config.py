"""Runtime configuration loaded from environment / app settings."""
from __future__ import annotations

import os
from dataclasses import dataclass

_DEFAULT_CONTAINER = "legacy-docs"
_DEFAULT_MAX_BYTES = 104_857_600  # 100 MiB
_DEFAULT_MAX_PATH = 1024  # Azure Blob name limit


@dataclass(frozen=True)
class Settings:
    """Immutable view of the gateway's runtime configuration."""

    storage_account_url: str
    docs_container: str
    allowed_group_ids: frozenset[str]
    allowed_prefixes: tuple[str, ...]
    max_download_bytes: int
    max_path_length: int


def _blob_url(env: dict[str, str]) -> str:
    explicit = env.get("DOCS_STORAGE_BLOB_URL")
    if explicit:
        return explicit.rstrip("/")
    account = env.get("DOCS_STORAGE_ACCOUNT")
    if not account:
        raise RuntimeError(
            "Configuration error: set DOCS_STORAGE_ACCOUNT or DOCS_STORAGE_BLOB_URL."
        )
    return f"https://{account}.blob.core.windows.net"


def _int(env: dict[str, str], key: str, default: int) -> int:
    raw = env.get(key)
    if raw is None or raw.strip() == "":
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise RuntimeError(f"Configuration error: {key} must be an integer.") from exc


def _csv(value: str) -> tuple[str, ...]:
    return tuple(item.strip() for item in value.split(",") if item.strip())


def load_settings(env: dict[str, str] | None = None) -> Settings:
    """Build a Settings object from the supplied env mapping (defaults to os.environ)."""
    env = dict(os.environ if env is None else env)
    return Settings(
        storage_account_url=_blob_url(env),
        docs_container=env.get("DOCS_CONTAINER", _DEFAULT_CONTAINER),
        allowed_group_ids=frozenset(_csv(env.get("ALLOWED_GROUP_IDS", ""))),
        allowed_prefixes=_csv(env.get("ALLOWED_PREFIXES", "")),
        max_download_bytes=_int(env, "MAX_DOWNLOAD_BYTES", _DEFAULT_MAX_BYTES),
        max_path_length=_int(env, "MAX_PATH_LENGTH", _DEFAULT_MAX_PATH),
    )
