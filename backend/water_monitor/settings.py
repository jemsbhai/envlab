from dataclasses import dataclass
import os


@dataclass
class Settings:
    nats_url: str = "nats://127.0.0.1:4222"
    nats_user: str = "pipeline"
    nats_password: str = ""
    mqtt_host: str = "127.0.0.1"
    mqtt_port: int = 1883
    mqtt_user: str = "pipeline"
    mqtt_password: str = ""
    database_path: str = "data/history.sqlite3"
    health_path: str = "data/worker-health.json"
    expire_seconds: int = 30
    window_seconds: int = 60
    history_days: int = 90

    @classmethod
    def from_env(cls):
        settings = cls(
            nats_url=os.getenv("NATS_URL", cls.nats_url),
            nats_user=os.getenv("NATS_USER", cls.nats_user),
            nats_password=os.getenv("NATS_PASSWORD", ""),
            mqtt_host=os.getenv("MQTT_HOST", cls.mqtt_host),
            mqtt_port=int(os.getenv("MQTT_PORT", "1883")),
            mqtt_user=os.getenv("MQTT_USER", "pipeline"),
            mqtt_password=os.getenv("MQTT_PASSWORD", ""),
            database_path=os.getenv("DATABASE_PATH", cls.database_path),
            health_path=os.getenv("HEALTH_PATH", cls.health_path),
            expire_seconds=int(os.getenv("SENSOR_EXPIRE_SECONDS", "30")),
            window_seconds=int(os.getenv("WINDOW_SECONDS", "60")),
            history_days=int(os.getenv("HISTORY_DAYS", "90")),
        )
        if min(settings.expire_seconds, settings.window_seconds, settings.history_days) <= 0:
            raise ValueError("expiry, window, and history settings must be positive")
        return settings
