"""Create a relocatable font configuration for older fontconfig versions."""

import os
import tempfile
from pathlib import Path
from xml.sax.saxutils import escape

RELATIVE_DIR = '<dir prefix="relative">../../fonts</dir>'
_runtime_config = None


def render_config(template: str, fonts_dir: Path) -> str:
    """Resolve the packaged font directory after installation, not at build time."""
    if RELATIVE_DIR not in template:
        raise ValueError("packaged fonts.conf has no bundled font directory")
    return template.replace(RELATIVE_DIR, f"<dir>{escape(str(fonts_dir.resolve()))}</dir>")


def configure(package_dir: Path) -> None:
    global _runtime_config
    if "FONTCONFIG_FILE" in os.environ:
        return
    template = package_dir / "share" / "etc" / "fonts" / "fonts.conf"
    if not template.is_file():
        return
    text = render_config(template.read_text(encoding="utf-8"), package_dir / "share" / "fonts")
    # Keep this directory alive for the lifetime of the imported module. The
    # package itself may be read-only; the config is private to this process.
    _runtime_config = tempfile.TemporaryDirectory(prefix="riasopy-fontconfig-")
    config = Path(_runtime_config.name) / "fonts.conf"
    config.write_text(text, encoding="utf-8")
    os.environ["FONTCONFIG_FILE"] = str(config)
