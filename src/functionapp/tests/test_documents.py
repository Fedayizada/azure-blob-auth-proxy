import pytest
from azure.core.exceptions import ResourceNotFoundError

from config import load_settings
from documents import DocumentError, DocumentService, normalize_blob_path


def _settings(**overrides):
    env = {
        "DOCS_STORAGE_ACCOUNT": "mydocsaccount",
        "ALLOWED_GROUP_IDS": "g1",
        "MAX_DOWNLOAD_BYTES": "1000",
    }
    env.update(overrides)
    return load_settings(env)


class _FakeDownloader:
    def __init__(self, content: bytes, content_type="application/pdf", etag="etag-1"):
        self._content = content
        self.size = len(content)
        content_settings = type("CS", (), {"content_type": content_type})()
        self.properties = type("P", (), {"etag": etag, "content_settings": content_settings})()

    def readall(self):
        return self._content


class _FakeBlobClient:
    def __init__(self, content=None, content_type="application/pdf", missing=False):
        self._content = content
        self._content_type = content_type
        self._missing = missing

    def download_blob(self, **_kwargs):
        if self._missing:
            raise ResourceNotFoundError("missing")
        return _FakeDownloader(self._content, self._content_type)


class _FakeContainer:
    def __init__(self, blobs: dict):
        self._blobs = blobs

    def get_blob_client(self, name):
        if name not in self._blobs:
            return _FakeBlobClient(missing=True)
        content, content_type = self._blobs[name]
        return _FakeBlobClient(content=content, content_type=content_type)


def _service(blobs, **overrides):
    return DocumentService(_settings(**overrides), container_client=_FakeContainer(blobs))


# --- normalize_blob_path -----------------------------------------------------

@pytest.mark.parametrize("raw", [None, "", "   ", "/", "\\"])
def test_normalize_rejects_empty(raw):
    with pytest.raises(DocumentError) as exc:
        normalize_blob_path(raw)
    assert exc.value.status == 400


def test_normalize_strips_leading_slash_and_backslashes():
    assert normalize_blob_path("/invoices\\2024\\INV-1.pdf") == "invoices/2024/INV-1.pdf"


@pytest.mark.parametrize(
    "raw",
    [
        "../../etc/passwd",
        "invoices/../../secret.pdf",
        "a//b",
        "a/./b",
        "https://evil.com/x",
        "with\x00null",
    ],
)
def test_normalize_rejects_traversal_and_garbage(raw):
    with pytest.raises(DocumentError) as exc:
        normalize_blob_path(raw)
    assert exc.value.status == 400


def test_normalize_enforces_allowed_prefixes():
    assert normalize_blob_path("invoices/x.pdf", allowed_prefixes=("invoices/",)) == "invoices/x.pdf"
    with pytest.raises(DocumentError) as exc:
        normalize_blob_path("contracts/x.pdf", allowed_prefixes=("invoices/",))
    assert exc.value.status == 403


def test_normalize_enforces_max_length():
    with pytest.raises(DocumentError) as exc:
        normalize_blob_path("a" * 50, max_length=10)
    assert exc.value.status == 400


# --- DocumentService.fetch ---------------------------------------------------

def test_fetch_returns_content_type_filename_and_etag():
    blobs = {"invoices/2024/INV-1.pdf": (b"%PDF fake", "application/pdf")}
    doc = _service(blobs).fetch("invoices/2024/INV-1.pdf")
    assert doc.content == b"%PDF fake"
    assert doc.content_type == "application/pdf"
    assert doc.filename == "INV-1.pdf"
    assert doc.etag == "etag-1"
    assert doc.path == "invoices/2024/INV-1.pdf"


def test_fetch_missing_blob_is_404():
    with pytest.raises(DocumentError) as exc:
        _service({}).fetch("invoices/missing.pdf")
    assert exc.value.status == 404


def test_fetch_enforces_size_limit():
    blobs = {"big.bin": (b"x" * 2000, "application/octet-stream")}
    with pytest.raises(DocumentError) as exc:
        _service(blobs).fetch("big.bin")
    assert exc.value.status == 413


def test_fetch_rejects_invalid_path_before_storage():
    with pytest.raises(DocumentError) as exc:
        _service({}).fetch("../escape")
    assert exc.value.status == 400
