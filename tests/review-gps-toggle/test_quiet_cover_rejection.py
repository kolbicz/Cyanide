#!/usr/bin/env python3
"""Source-contract check for quiet-cover rejection cleanup (not an iOS runtime test)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Cyanide/SceneDelegate.m").read_text()

start = SOURCE.index("if (settings_switcher_removal_pending()) {")
end = SOURCE.index("        return;", start)
branch = SOURCE[start:end]
assert "[self hideQuietCover];" in branch
assert "if (self.actionInProgress)" in SOURCE[:start]
assert "if (requester) requester(NO, busy);" in branch
print("quiet-cover rejection source contract: PASS")
