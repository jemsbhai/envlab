# Dewin interactive architecture

Open `index.html` directly in a browser, or serve this directory at
`/architecture/` on the existing gateway. The page is self-contained: no build,
runtime dependencies, external fonts, or telemetry requests. Its links to the
shared contracts and visual inspiration are ordinary outbound links.

Click the isometric components to inspect responsibilities, protocols, subjects,
and storage. Trace a packet or choose an individual step. Switch between a
public venue, private owner, private visitor, and stale-sensor scenario. The
phone-disconnection control explains recovery using persisted history.

All illustrated readings, users, positions, and flows are synthetic. This is an
architecture explanation, not a dashboard connected to live measurements.

Architecture follows `backend/docs/api-v1.md`, `water_monitor/dewin_bus.py`,
`spatial.py`, `spatial_worker.py`, and `gateway.py`. The illustration is original;
the fine-line isometric lighting approach is inspired by [ISO-GLOW](https://isoglow.dev/).
No reference-site source, assets, or branding is included.
