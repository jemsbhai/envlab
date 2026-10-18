"""Print a Home Assistant dashboard for the simulator's stable entity IDs."""
import argparse
import json
import re

from .ha import entity_key


def dashboard(devices=3):
    cards = []
    for index in range(devices):
        row = {"device_id": f"sim-pico-{index+1:02}", "sensor_id": "water-1", "metric": "temperature"}
        entities = ["sensor." + re.sub("[^a-z0-9_]", "_", entity_key(row, aggregate)) for aggregate in (False, True)]
        cards.extend([
            {"type": "entities", "title": row["device_id"] + " · SIMULATED", "entities": entities},
            {"type": "history-graph", "title": "Temperature and rolling mean", "hours_to_show": 1, "entities": entities},
        ])
    return {"title": "Dewin telemetry", "views": [{"title": "Data pipes", "path": "pipes", "cards": cards}]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--devices", type=int, default=3)
    args = parser.parse_args()
    print(json.dumps(dashboard(args.devices), indent=2, ensure_ascii=False))
