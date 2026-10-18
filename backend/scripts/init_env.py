"""Create local configuration without overwriting existing credentials."""
from pathlib import Path
import secrets

path = Path(__file__).resolve().parents[1] / ".env"
existing = path.exists()
template = path.read_text(encoding="utf-8") if existing else path.with_name(".env.example").read_text(encoding="utf-8")
for name in ("SENSOR_PASSWORD", "PIPELINE_PASSWORD", "HA_PASSWORD", "VIEWER_PASSWORD",
             "PORTAINER_ADMIN_PASSWORD", "HA_ADMIN_PASSWORD"):
    placeholder = f"{name}=replace-with-random-password"
    if placeholder in template:
        template = template.replace(placeholder, f"{name}={secrets.token_hex(24)}")
    elif not any(line.startswith(name + "=") for line in template.splitlines()):
        template += f"\n{name}={secrets.token_hex(24)}\n"
with path.open("w" if existing else "x", encoding="utf-8", newline="\n") as stream:
    stream.write(template)
path.chmod(0o600)
runtime = path.parent / ".runtime"
runtime.mkdir(exist_ok=True)
runtime.chmod(0o700)
values = dict(line.split("=", 1) for line in template.splitlines()
              if line and not line.startswith("#") and "=" in line)
admin_file = runtime / "portainer-admin-password"
admin_file.write_text(values["PORTAINER_ADMIN_PASSWORD"], encoding="utf-8")
admin_file.chmod(0o600)
print("Configured .env credentials; existing non-placeholder values were preserved.")
