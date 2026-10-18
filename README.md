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
| Identification kiosk (card + face check-in) | [Kiosk integration](docs/kiosk-presence-integration.md): the kiosk is a Socket.IO client submitting positions for checked-in people; no backend change, no MQTT device |
| Interactive architecture | [Live explainer](https://dewin-api.cbnsndwch.dev/architecture/), [offline HTML](backend/docs/architecture/index.html) |

`AGENTS.md` directs coding agents to the same contracts. All examples/mock data
are synthetic. The app sends demo auth `{"token":"0"}` (string `"0"`);
sensor MQTT needs no username/password. No secret exchange is needed.
Management credentials remain private and must never be committed.

## Current architecture and status

```text
Sensor nodes -- MQTT 3.1.1 --> NATS + JetStream --> NEX processing
                                  ^                   |
Phone -- Socket.IO --> API gateway                    |
Phone <-- Socket.IO -- gateway <-- persisted exposure results
```

The MQTT broker, JetStream, NEX, and simulator run on the existing Debian Pi at
`10.104.0.82`. The real Socket.IO gateway and NEX spatial worker are deployed
and verified through the public Cloudflare endpoint. See the
[Pi operating notes](backend/docs/deployment-zerod.md) for validation details.
The live API is `https://dewin-api.cbnsndwch.dev`; connect with `{"token":"0"}`
to use shared identity `demo-ios`. All demo phones share its timeline and live results.
Optional valid tokens still select separate identities. MQTT sensors omit
username/password on the demo LAN. A local mock is also available. JetStream streams/KV store
positions, deduplication receipts, and exposure history; application workers
perform spatial joins. Private sensor ownership is server-controlled. No
frontend or sensor needs a native NATS client.

The current mobile scope is air/water plus GPS, live enrichment, and history.
HA is stopped with its data preserved; food tracking is deferred.

## Repository layout

```text
backend/   NATS/MQTT/NEX, real Socket.IO gateway, contracts, Swift starter, mock
docs/      Team/agent handoffs and hardware documentation
sensors/   Sensor firmware and publishing integrations (teammates)
pi/        Identification kiosk: face check, card sessions, Dewin presence client, Supabase record
nano/      RC522 card reader firmware (Nano 33 IoT), tamper telemetry
tools/     Laptop helpers (spoken kiosk feedback)
```

The kiosk feeds the same pipeline as a phone: while a person is checked in, it
submits `location:update` for them at its configured coordinates (see
[kiosk integration](docs/kiosk-presence-integration.md)). Its original standalone
design, with the JSONL/Supabase visit record, is kept in
[kiosk prototype notes](docs/kiosk-prototype.md); that record is the kiosk's own
and is not a sensor/app data contract. Sensor integration publishes MQTT using
the contract linked above.

Built at a hardware hackathon, October 2026. Hobby-grade sensor values describe
measurements; they do not establish health or drinking-water safety.
