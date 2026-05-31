"""Pytest configuration: ensure the repo root is importable as cepheus_build.*."""

from __future__ import annotations

import sys
from pathlib import Path

# Insert the repo root so `import cepheus_build` works regardless of how
# pytest is invoked (e.g. from a venv that lacks the package installed).
REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))
