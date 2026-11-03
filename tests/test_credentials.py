import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("credentials", Path(__file__).parents[1] / "credentials.py")
credentials = importlib.util.module_from_spec(spec)
spec.loader.exec_module(credentials)


class CredentialsTests(unittest.TestCase):
    def test_first_run_creates_private_directory_and_file(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "new-state" / "credentials.json"
            credentials.save_credentials(target, '{"username":"demo","password":"example"}')
            self.assertEqual(json.loads(target.read_text())["username"], "demo")
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(target.parent.stat().st_mode), 0o700)

    def test_replaces_old_file_without_leaking_extra_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "credentials.json"
            target.write_text('{"username":"old","password":"old"}')
            os.chmod(target, 0o644)
            credentials.save_credentials(target, '{"username":"demo","password":"<new>\\nsecret","extra":"ignored"}')
            self.assertEqual(json.loads(target.read_text()), {"username": "demo", "password": "<new>\nsecret"})
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
            self.assertEqual(list(Path(directory).iterdir()), [target])

    def test_invalid_input_preserves_existing_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "credentials.json"
            original = '{"username":"demo","password":"keep"}'
            target.write_text(original)
            for value in ('{}', '[]', 'null', '{"username":"demo","password":""}', 'invalid', 'x' * 65537):
                with self.subTest(value=value[:50]), self.assertRaises((ValueError, TypeError)):
                    credentials.save_credentials(target, value)
                self.assertEqual(target.read_text(), original)


if __name__ == "__main__":
    unittest.main()
