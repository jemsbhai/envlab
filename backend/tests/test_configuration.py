"""Deployment configuration checks for enrollment preservation and CORS."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from water_monitor.gateway import Gateway

ROOT = Path(__file__).resolve().parents[1]


class InitConfigurationTests(unittest.TestCase):
    def test_bootstrap_then_reinitialize_preserves_enrollment_and_revocation(self):
        with TemporaryDirectory() as directory:
            project = Path(directory)
            (project / "scripts").mkdir()
            (project / "deploy").mkdir()
            shutil.copy(ROOT / "scripts/init_env.py", project / "scripts/init_env.py")
            shutil.copy(ROOT / ".env.example", project / ".env.example")
            shutil.copy(ROOT / "deploy/devices.example.json", project / "deploy/devices.example.json")
            command = [sys.executable, str(project / "scripts/init_env.py")]
            subprocess.run(command, check=True, capture_output=True, text=True, timeout=10)
            values = dict(line.split("=", 1) for line in (project / ".env").read_text().splitlines()
                          if line and not line.startswith("#") and "=" in line)
            clients_file = project / ".runtime/api-clients.json"
            clients = json.loads(clients_file.read_text())
            self.assertEqual(clients["clients"][0]["tokenSha256"],
                             hashlib.sha256(values["API_DEMO_TOKEN"].encode()).hexdigest())
            # Revoke the bootstrap demo user, enroll another user, and rotate a
            # token manually. Setup must neither restore nor replace any entry.
            custom = {"clients": [{"userId": "demo-other", "tokenSha256": "c"*64},
                                  {"userId": "new-teammate", "tokenSha256": "d"*64}]}
            saved = (json.dumps(custom, indent=4)+"\n").encode()
            clients_file.write_bytes(saved)
            subprocess.run(command, check=True, capture_output=True, text=True, timeout=10)
            self.assertEqual(clients_file.read_bytes(), saved)
            self.assertEqual(values["API_DEMO_TOKEN"], dict(line.split("=", 1) for line in
                             (project / ".env").read_text().splitlines()
                             if line.startswith("API_DEMO_TOKEN="))["API_DEMO_TOKEN"])


class OriginConfigurationTests(unittest.TestCase):
    def test_gateway_defaults_for_unset_or_empty_origins_and_uses_custom_origins(self):
        with TemporaryDirectory() as directory:
            clients = Path(directory) / "clients.json"
            clients.write_text('{"clients": []}')
            for value in (None, "", "https://ios-demo.example,https://dashboard.example"):
                with self.subTest(value=value), patch.dict(os.environ, {
                        "API_CLIENTS_PATH": str(clients), "API_CURSOR_SECRET": "s"*48}):
                    if value is None:
                        os.environ.pop("API_ALLOWED_ORIGINS", None)
                    else:
                        os.environ["API_ALLOWED_ORIGINS"] = value
                    allowed = Gateway().sio.eio.cors_allowed_origins
                    if value:
                        self.assertEqual(allowed, value.split(","))
                    else:
                        self.assertIn("https://dewin-api.cbnsndwch.dev", allowed)
                        self.assertIn("http://localhost:5173", allowed)
                        self.assertNotIn("", allowed)

    @unittest.skipUnless(shutil.which("docker"), "Docker Compose CLI needed to verify deployment interpolation")
    def test_compose_forwards_custom_origin_from_env_file(self):
        with TemporaryDirectory() as directory:
            env_file = Path(directory) / "demo.env"
            env_file.write_text((ROOT / ".env.example").read_text() +
                                "\nAPI_ALLOWED_ORIGINS=https://ios-demo.example\n")
            environment = dict(os.environ)
            environment.pop("API_ALLOWED_ORIGINS", None)
            result = subprocess.run(["docker", "compose", "--project-directory", str(ROOT),
                                     "--env-file", str(env_file), "-f", str(ROOT / "compose.yaml"),
                                     "config", "--format", "json"],
                                    env=environment, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, "Docker Compose configuration did not resolve")
            configuration = json.loads(result.stdout)
            self.assertEqual(configuration["services"]["gateway"]["environment"]["API_ALLOWED_ORIGINS"],
                             "https://ios-demo.example")


if __name__ == "__main__":
    unittest.main()
