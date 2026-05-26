"""jinja-shadow-lsp: a Jinja template language server built on the
'shadow buffer' technique -- compile the template into a virtual
host-language file, run host tooling on it, and map results back.

v1 targets Python-hosted templates (``*.py.j2``) and provides Jinja syntax
diagnostics. It does not format anything.
"""

__version__ = "0.1.0"
