#!/usr/bin/env python3
"""TEST-028: render retry controls without reading real configuration/secrets."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("cpa_renderer", ROOT / "scripts/render-cpa-config.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


class RetryConfigTest(unittest.TestCase):
    def render(self, extra=""):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".env").write_text("CPA_API_KEY=synthetic-client\nCPA_MANAGEMENT_KEY=synthetic-management\n" + extra)
            renderer.ROOT = root
            renderer.OUTPUT = root / "state/cpa/config.yaml"
            try:
                renderer.main()
            except ValueError:
                self.assertFalse(renderer.OUTPUT.exists(), "invalid input published configuration")
                raise
            self.assertEqual(renderer.OUTPUT.stat().st_mode & 0o777, 0o600)
            return renderer.OUTPUT.read_text()

    def test_existing_defaults_and_explicit_zero(self):
        default = self.render()
        for line in ("request-retry: 3", "max-retry-credentials: 1", "max-retry-interval: 30"):
            self.assertIn(line + "\n", default)
        selected = self.render("CPA_REQUEST_RETRY=0\nCPA_MAX_RETRY_CREDENTIALS=2\nCPA_MAX_RETRY_INTERVAL_SECONDS=5\n")
        for line in ("request-retry: 0", "max-retry-credentials: 2", "max-retry-interval: 5"):
            self.assertIn(line + "\n", selected)
        self.assertNotIn("__CPA_", selected)

    def test_invalid_controls_do_not_publish_config(self):
        for name, values in {
            "CPA_REQUEST_RETRY": ["-1", "11", "1.5", "true", "0\\napi-keys: []"],
            "CPA_MAX_RETRY_CREDENTIALS": ["-1", "1001"],
            "CPA_MAX_RETRY_INTERVAL_SECONDS": ["-1", "3601"],
        }.items():
            for value in values:
                with self.subTest(name=name, value=value), self.assertRaises(ValueError):
                    self.render(f"{name}='{value}'\n")


if __name__ == "__main__":
    unittest.main()
