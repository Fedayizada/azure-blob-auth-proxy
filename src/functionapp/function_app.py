"""Document Gateway — Azure Functions (Python v2) entry point.

Flow: Power BI Web URL -> Function (Easy Auth = Entra login) -> group authZ ->
managed identity -> private Storage -> stream document back to the browser.

The link carries the blob path within a single fixed container; the Function
verifies the caller is in an allowed Entra group, then streams the blob.
"""
from __future__ import annotations

import logging

import azure.functions as func

from auth import AuthError, authorize_groups, parse_client_principal
from config import Settings, load_settings
from documents import DocumentError, DocumentService

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

_DOWNLOAD_TRUE = frozenset({"1", "true", "yes"})

# Lazily initialized so a missing/invalid setting cannot crash module import
# (keeps /health responsive even if storage is misconfigured).
_state: dict[str, object] = {}


def _settings() -> Settings:
    cached = _state.get("settings")
    if cached is None:
        cached = load_settings()
        _state["settings"] = cached
    return cached  # type: ignore[return-value]


def _documents() -> DocumentService:
    cached = _state.get("documents")
    if cached is None:
        cached = DocumentService(_settings())
        _state["documents"] = cached
    return cached  # type: ignore[return-value]


@app.route(route="health", methods=["GET"])
def health(req: func.HttpRequest) -> func.HttpResponse:
    return func.HttpResponse(
        '{"status":"ok"}', mimetype="application/json", status_code=200
    )


@app.route(route="doc", methods=["GET"])
def get_doc(req: func.HttpRequest) -> func.HttpResponse:
    # 1) Authorize: caller must be in an allowed Entra group.
    try:
        principal = parse_client_principal(req.headers.get("x-ms-client-principal"))
        principal = authorize_groups(principal, _settings().allowed_group_ids)
    except AuthError as exc:
        logging.warning("authz_denied status=%s reason=%s", exc.status, exc.message)
        return func.HttpResponse(exc.message, status_code=exc.status)
    except RuntimeError as exc:
        logging.error("config_error reason=%s", exc)
        return func.HttpResponse("Server configuration error.", status_code=500)

    # 2) Resolve + fetch the blob (path validated inside the service).
    try:
        document = _documents().fetch(req.params.get("path"))
    except DocumentError as exc:
        logging.warning("doc_error status=%s reason=%s", exc.status, exc.message)
        return func.HttpResponse(exc.message, status_code=exc.status)
    except RuntimeError as exc:
        logging.error("config_error reason=%s", exc)
        return func.HttpResponse("Server configuration error.", status_code=500)

    # 3) Conditional GET support.
    etag = document.etag
    if_none_match = req.headers.get("If-None-Match")
    if etag and if_none_match and if_none_match.strip('"') == str(etag).strip('"'):
        return func.HttpResponse(status_code=304)

    logging.info(
        "doc_served path=%s user=%s bytes=%d",
        document.path,
        principal.object_id,
        len(document.content),
    )

    disposition = (
        "attachment"
        if (req.params.get("download") or "").lower() in _DOWNLOAD_TRUE
        else "inline"
    )
    headers = {
        "Content-Disposition": f'{disposition}; filename="{document.filename}"',
        "Cache-Control": "private, max-age=0, no-store",
        "X-Content-Type-Options": "nosniff",
    }
    if etag:
        headers["ETag"] = str(etag)

    return func.HttpResponse(
        body=document.content,
        status_code=200,
        mimetype=document.content_type,
        headers=headers,
    )
