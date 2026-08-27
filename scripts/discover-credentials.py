#!/usr/bin/env python3
"""Print safe provider/account discovery information for Crush setup."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from config.provider_credentials import discover_credentials

print(json.dumps([c.__dict__ for c in discover_credentials()], indent=2))
