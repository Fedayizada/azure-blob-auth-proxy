"""Resolve a blob path from the request and stream the document.

The Power BI link carries the blob's path *within a single, fixed container*
(pinned in configuration, never supplied by the caller). Because the container is
fixed server-side and Azure Blob is a flat namespace, a caller cannot escape the
container, reach another container, or hit another storage account: an unknown
path is simply a 404.

We still sanitize the path (reject backslashes, leading slashes, empty / "." /
".." segments, control chars, URLs) and optionally constrain it to an allowed
prefix list, as defense in depth. Storage access uses the Function's managed
identity (no keys/SAS). Content type comes from the blob's own metadata.
"""
from __future__ import annotations

from dataclasses import dataclass

from azure.core.exceptions import ResourceNotFoundError
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

_DEFAULT_CONTENT_TYPE = "application/octet-stream"


@dataclass(frozen=True)
class Document:
    """A fetched document: its path, bytes, content type, filename, and ETag."""

    path: str
    content: bytes
    content_type: str
    filename: str
    etag: str | None


class DocumentError(Exception):
    """Raised for any document validation or retrieval failure."""

    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


def normalize_blob_path(
    raw: str | None,
    allowed_prefixes: tuple[str, ...] = (),
    max_length: int = 1024,
) -> str:
    """Validate and normalize a caller-supplied blob path within the fixed container.

    Raises DocumentError(400) for a malformed path and DocumentError(403) when an
    allowed-prefix list is configured and the path is outside it.
    """
    if not raw or not raw.strip():
        raise DocumentError(400, "Missing 'path' parameter.")

    path = raw.strip().replace("\\", "/").lstrip("/")
    if not path:
        raise DocumentError(400, "Invalid 'path' parameter.")
    if len(path) > max_length:
        raise DocumentError(400, "Path exceeds maximum length.")
    if "://" in path:
        raise DocumentError(400, "Invalid 'path' parameter.")
    if any(ord(ch) < 32 for ch in path):
        raise DocumentError(400, "Invalid 'path' parameter.")
    if any(segment in ("", ".", "..") for segment in path.split("/")):
        raise DocumentError(400, "Invalid 'path' parameter.")
    if allowed_prefixes and not any(path.startswith(p) for p in allowed_prefixes):
        raise DocumentError(403, "Path is not within an allowed location.")
    return path


def _sanitize_filename(name: str) -> str:
    cleaned = name.replace('"', "").replace("\r", "").replace("\n", "").strip()
    return cleaned or "document"


class DocumentService:
    """Streams blobs from the fixed container via managed identity."""

    def __init__(self, settings, container_client=None) -> None:
        self._settings = settings
        if container_client is not None:
            self._container = container_client
        else:
            credential = DefaultAzureCredential()
            service = BlobServiceClient(
                account_url=settings.storage_account_url, credential=credential
            )
            self._container = service.get_container_client(settings.docs_container)

    def fetch(self, raw_path: str | None) -> Document:
        """Validate, download, and return a document, enforcing the size guard."""
        path = normalize_blob_path(
            raw_path, self._settings.allowed_prefixes, self._settings.max_path_length
        )
        blob_client = self._container.get_blob_client(path)
        try:
            downloader = blob_client.download_blob(max_concurrency=2)
        except ResourceNotFoundError as exc:
            raise DocumentError(404, "Document not found.") from exc

        size = getattr(downloader, "size", None)
        if size is not None and size > self._settings.max_download_bytes:
            raise DocumentError(413, "Document exceeds the gateway size limit.")

        content = downloader.readall()
        if len(content) > self._settings.max_download_bytes:
            raise DocumentError(413, "Document exceeds the gateway size limit.")

        return Document(
            path=path,
            content=content,
            content_type=_content_type(downloader),
            filename=_sanitize_filename(path.rsplit("/", 1)[-1]),
            etag=_etag(downloader),
        )


def _content_type(downloader) -> str:
    properties = getattr(downloader, "properties", None)
    settings = getattr(properties, "content_settings", None)
    content_type = getattr(settings, "content_type", None)
    return content_type or _DEFAULT_CONTENT_TYPE


def _etag(downloader) -> str | None:
    properties = getattr(downloader, "properties", None)
    return getattr(properties, "etag", None)
