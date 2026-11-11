import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("import_model", Path(__file__).resolve().parents[1] / "scripts/import-model.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ModelValidationTests(unittest.TestCase):
    def test_corrupt_and_wrong_network_inputs_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            data = b"synthetic validation fixture, not real model weights"
            (source / "weights.safetensors").write_bytes(data)
            manifest = {"architecture": "mlxdlss.neural-rendering-transformer.v1", "weights": {
                "file": "weights.safetensors", "sha256": hashlib.sha256(data).hexdigest(),
                "tensors": [{"name": "block70.layer0.out_conv_weight"}]}}
            def save():
                (source / "manifest.json").write_text(json.dumps(manifest))
            save()
            self.assertEqual(module.validate(source), source.resolve())
            (source / "weights.safetensors").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "checksum"):
                module.validate(source)
            (source / "weights.safetensors").write_bytes(data)
            manifest["weights"]["tensors"] = [{"name": "small.network"}]
            save()
            with self.assertRaisesRegex(ValueError, "71-block"):
                module.validate(source)
            manifest["weights"]["file"] = "../outside.safetensors"
            save()
            with self.assertRaisesRegex(ValueError, "Expected weights"):
                module.validate(source)


if __name__ == "__main__":
    unittest.main()
