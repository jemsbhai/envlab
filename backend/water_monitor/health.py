import json
import os
from pathlib import Path
import time


def main():
    try:
        state = json.loads(Path(os.getenv("HEALTH_PATH", "/data/worker-health.json")).read_text())
        return 0 if state["ready"] and time.time() - state["updated_at"] < 15 else 1
    except (OSError, ValueError, KeyError):
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
