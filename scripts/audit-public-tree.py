#!/usr/bin/env python3
"""Check the actual Git index for private/local inputs before publication."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).split(b"\0")
errors = []
for entry in tracked:
    if not entry:
        continue
    name = entry.decode("utf-8")
    path = Path(name)
    if any(part in {"models", "artifacts", "vendor", ".build", "build", "dist", "results", "__pycache__"} for part in path.parts):
        errors.append(f"Local/generated directory: {name}")
    if path.suffix.lower() in {".dll", ".dylib", ".safetensors", ".metallib", ".zip", ".dmg", ".log", ".pyc"} or any(p.endswith((".app", ".dlssmodel")) for p in path.parts):
        errors.append(f"Binary/model/archive: {name}")
    data = subprocess.check_output(["git", "show", ":" + name], cwd=root)
    if len(data) > 2 * 1024 * 1024:
        errors.append(f"Unexpected large file: {name}")
    try:
        content = data.decode("utf-8")
    except UnicodeDecodeError:
        errors.append(f"Unexpected binary: {name}")
        continue
    if re.search(r"/Users/[A-Za-z0-9._-]+/", content):
        errors.append(f"Personal absolute path: {name}")
    if re.search(r"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}|-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----)", content):
        errors.append(f"Potential credential: {name}")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Public index audit passed: {sum(bool(p) for p in tracked)} text files; no models, binaries, local paths, or matching credentials.")
