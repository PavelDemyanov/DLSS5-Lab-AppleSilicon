#!/usr/bin/env python3
"""Validate and copy a user-supplied HT package for a local build. No downloads."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def validate(source):
    source = Path(source).resolve(strict=True)
    if not source.is_dir():
        raise ValueError("Supply a prepared HT .dlssmodel directory, not a DLL or an archive.")
    manifest = json.loads((source / "manifest.json").read_text())
    if manifest.get("architecture") != "mlxdlss.neural-rendering-transformer.v1":
        raise ValueError("This is not the supported HT architecture.")
    weights = manifest.get("weights", {})
    if weights.get("file") != "weights.safetensors":
        raise ValueError("Expected weights.safetensors in the model directory.")
    actual = hashlib.sha256()
    with (source / "weights.safetensors").open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            actual.update(chunk)
    if actual.hexdigest() != weights.get("sha256"):
        raise ValueError("Model weights do not match their manifest checksum.")
    # The tested HT package is the 71-block network. Small is a different path.
    names = {tensor.get("name") for tensor in weights.get("tensors", [])}
    if "block70.layer0.out_conv_weight" not in names:
        raise ValueError("Supply the HT (71-block) package, not the Small network.")
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    source = validate(args.source)
    if args.check_only:
        print("HT package checksum and architecture passed. Nothing was copied.")
        return
    target = ROOT / "models/NeuralRendering-HT.dlssmodel"
    if target.exists():
        raise ValueError("A local model already exists. Move it aside before importing a replacement.")
    target.parent.mkdir(parents=True, exist_ok=True)
    # Copy only the two validated inputs, never unrelated files in the directory.
    with tempfile.TemporaryDirectory(prefix="import-", dir=target.parent) as temporary:
        stage = Path(temporary) / target.name
        stage.mkdir()
        for name in ("manifest.json", "weights.safetensors"):
            shutil.copyfile(source / name, stage / name)
        validate(stage)
        stage.rename(target)
    print("HT package imported for local use. Do not distribute the model or apps containing it.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(str(error)) from None
