"""Loads .env into os.environ on import (shell wins via setdefault)."""
import os
try:
    for line in open(".env"):
        line = line.strip()
        if line and not line.startswith("#"):
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
except FileNotFoundError:
    pass
