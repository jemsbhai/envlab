# envlab / Dewin

Environmental exposure tracking: phones submit positions, sensor nodes publish
air/water measurements with coordinates, and the backend attaches nearby
authorized readings to each user's timeline.

## Team entry points

| Working on | Start here |
| --- | --- |
| iOS / map / time scrubber | [iOS agent handoff](docs/ios-agent-handoff.md) |
| Sensor firmware / publishing | [Sensor agent handoff](docs/sensor-agent-handoff.md) |
| App API payloads | [Socket.IO API v1](backend/docs/api-v1.md) |
| MQTT payloads | [Sensor MQTT v1](backend/docs/pico-contract.md) |
| Backend / Pi operations | [Backend README](backend/README.md), [deployed Pi](backend/docs/deployment-zerod.md) |

`AGENTS.md` directs coding agents to the same contracts. All examples/mock data
are synthetic. Obtain actual credentials privately; never commit them.

## Current architecture and status

```text
Sensor nodes -- MQTT 3.1.1 --> NATS + JetStream --> NEX processing
                                  ^                   |
Phone -- Socket.IO --> API gateway                    |
Phone <-- Socket.IO -- gateway <-- persisted exposure results
```

The MQTT broker, JetStream, NEX, and simulator run on the existing Debian Pi at
`10.104.0.82`. **The new real Socket.IO gateway is pending implementation**;
use the runnable local mock for iOS integration now. JetStream stores incoming
messages; application workers perform spatial joins. Private sensor ownership
is server-controlled. No frontend or sensor needs a native NATS client.

The current mobile scope is air/water plus GPS, live enrichment, and history.
HA is stopped with its data preserved; food tracking is deferred.

## Repository layout

```text
backend/   NATS/MQTT/NEX setup, contracts, fixtures, Swift starter, local API mock
docs/      Team/agent handoffs and hardware documentation
sensors/   Sensor firmware and publishing integrations (teammates)
pi/        Existing face-check-in kiosk prototype
nano/      Existing RC522/card-reader prototype
```

The previous JSONL/Supabase/kiosk architecture is preserved in
[kiosk prototype notes](docs/kiosk-prototype.md). Its source is retained under
`pi/` and `nano/`. It is not the current sensor/app data contract; new sensor
integration publishes MQTT using the contract linked above.

Built at a hardware hackathon, October 2026. Hobby-grade sensor values describe
measurements; they do not establish health or drinking-water safety.
