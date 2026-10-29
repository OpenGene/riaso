"""riasopy -- spatial omics data analysis (Rust core).

Thin shell package: the real implementation lives in the native extension
``riasopy.riasopy`` (the maturin build artifact). See ``riasopy.riasopy.__all__``
for ``__all__``.
"""

from pathlib import Path as _Path
from ._fontconfig import configure as _configure_fontconfig

# fontconfig 2.13.1 cannot resolve prefix="relative". Generate a private config
# with the installed font path before loading the extension; respect user config.
_configure_fontconfig(_Path(__file__).resolve().parent)
del _Path, _configure_fontconfig

from .riasopy import *
from .riasopy import __all__

__version__ = "0.1.0"
