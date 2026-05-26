"""Map a Jinja template to its host language.

The jinja layer is host-agnostic; the *host* of a template (the language it
generates) is inferred from the extension beneath the jinja suffix:
``foo.py.j2`` -> ``.py`` -> ``python``. The table is overridable by the
caller via ``initializationOptions`` (see :mod:`config`).
"""

from __future__ import annotations

import re
from urllib.parse import unquote, urlparse

_JINJA_SUFFIX_RE = re.compile(r"\.(?:j2|jinja2?|jinja)$", re.IGNORECASE)

# Default inner-extension -> language id. Intentionally small; the caller
# configures whatever hosts it has downstream servers for.
DEFAULT_EXTENSION_LANGUAGES: dict[str, str] = {
    ".py": "python",
    ".pyi": "python",
}


def _path_from_uri(uri: str) -> str:
    parsed = urlparse(uri)
    if parsed.scheme in ("file", ""):
        return unquote(parsed.path)
    return uri


def inner_extension(uri: str) -> str | None:
    """Extension beneath the jinja suffix, lowercased (``foo.py.j2`` -> ``.py``).

    None if the name has no jinja suffix or no inner extension.
    """
    path = _path_from_uri(uri)
    base = path.rsplit("/", 1)[-1]
    stripped, n = _JINJA_SUFFIX_RE.subn("", base)
    if n == 0:
        return None
    dot = stripped.rfind(".")
    if dot <= 0:  # no inner extension, or a dotfile like ".env.j2"
        return None
    return stripped[dot:].lower()


def template_basename(uri: str) -> str:
    """Filename with the jinja suffix stripped (``foo.py.j2`` -> ``foo.py``)."""
    base = _path_from_uri(uri).rsplit("/", 1)[-1]
    return _JINJA_SUFFIX_RE.sub("", base)


def shadow_uri(template_uri: str) -> str:
    """In-project URI for the shadow: the template URI with the jinja suffix
    stripped (``…/foo.py.j2`` -> ``…/foo.py``).

    Keeping the shadow at its in-project path lets the downstream server
    resolve it (and its imports) within the project, instead of a temp dir.
    """
    return _JINJA_SUFFIX_RE.sub("", template_uri)


def fs_path(uri: str | None) -> str | None:
    """Filesystem path for a file:// URI, else None."""
    if not uri:
        return None
    parsed = urlparse(uri)
    return unquote(parsed.path) if parsed.scheme == "file" else None


def language_for_uri(
    uri: str, ext_languages: dict[str, str] | None = None
) -> str | None:
    """Host language id for a template URI, or None if unknown.

    ``ext_languages`` (from caller config) is merged over the defaults.
    """
    ext = inner_extension(uri)
    if ext is None:
        return None
    table = {**DEFAULT_EXTENSION_LANGUAGES, **(ext_languages or {})}
    return table.get(ext)
