# Multi Buy Service

Multi Buy is a distributed packet deduplication mechanism used by Helium Packet Router (HPR). When multiple hotspots hear the same LoRaWAN uplink, HPR needs to decide how many copies to purchase. The Multi Buy Service provides a shared atomic counter so that load-balanced HPR instances agree on a global count.

## How It Works

1. A LoRaWAN device transmits an uplink.
2. Multiple hotspots receive the packet and forward it to HPR.
3. For each copy, HPR generates a key from `sha256(packet_hash || lns_address)` and sends it to the Multi Buy Service along with the hotspot's public key (base58) and LoRaWAN region.
4. The service atomically increments a counter for that key and returns the current count. It may also return a `denied` flag, allowing the service to reject packets from specific hotspots or regions.
5. If the counter exceeds `max_copies` (configured per route or per session key filter) or the packet is denied, it is dropped.
6. Only the allowed, non-denied copies are forwarded to the LNS.

The key insight is that without a shared counter, each HPR instance only sees its own local traffic. If you run a single HPR instance, local ETS counters are sufficient. If you run multiple load-balanced instances, you need the Multi Buy Service to coordinate.

## Modes of Operation

### 1. Default (Helium-hosted) Multi Buy

HPR connects to a single configured Multi Buy Service endpoint. Every route uses this shared service. This is the standard Helium network setup.

### 2. Custom (Per-Route) Multi Buy

A route can specify its own Multi Buy Service endpoint. This lets an LNS operator run a private Multi Buy Service for their routes, independent of the Helium-hosted one.

The route's `multi_buy` field is a protobuf message with:

| Field                 | Type             | Description                                             |
| --------------------- | ---------------- | ------------------------------------------------------- |
| `protocol`            | `http` / `https` | Transport protocol for the gRPC connection              |
| `host`                | string           | Hostname of the custom Multi Buy Service                |
| `port`                | integer          | Port number                                             |
| `fail_on_unavailable` | bool             | Behavior when the service cannot be reached (see below) |

When a route has a custom Multi Buy configured, HPR connects to that endpoint instead of the default one.

Custom Multi Buy is managed via the [helium-config-service-cli](https://github.com/helium/helium-config-service-cli):

```bash
# Set a custom Multi Buy Service on a route
helium-config-service-cli route update set-multi-buy \
  --route-id <ROUTE_ID> \
  --protocol <http|https> \
  --host <HOST> \
  --port <PORT> \
  --fail-on-unavailable \  # optional, omit for fail-open behavior
  --commit

# Remove custom Multi Buy (revert to HPR's default service)
helium-config-service-cli route update remove-multi-buy \
  --route-id <ROUTE_ID> \
  --commit
```

Omit `--commit` to preview changes without applying them.

### 3. ETS-Only (No External Service)

Set `HPR_MULTI_BUY_ENABLED=false`. HPR uses only local in-memory ETS counters. This works correctly for a **single HPR instance** but will over-count if you run multiple instances behind a load balancer, since each instance maintains its own independent counter.

## What Happens When the Service Is Unavailable

The behavior depends on the mode and configuration:

### Default Multi Buy unavailable

If the default Helium-hosted service fails to respond, the **packet is treated as free** (`{ok, true}`). This is a fail-open design — HPR will still forward the packet to the LNS, but the packet will not be charged for. This prevents service outages from blocking all LoRaWAN traffic.

### Custom Multi Buy unavailable

Controlled by the `fail_on_unavailable` flag on the route:

- **`fail_on_unavailable = false`** (default): Falls back to the default Multi Buy Service. If the default service is also unavailable, the packet is free (same fail-open behavior as above).
- **`fail_on_unavailable = true`**: The packet is **dropped** (`{error, fail_on_unavailable}`). This is a fail-closed mode for operators who prefer to reject packets rather than risk duplicate billing.

### Backoff mechanism

When a custom Multi Buy endpoint fails, HPR enters an exponential backoff for that specific channel (identified by route ID + protocol + host + port). During backoff:

- No gRPC calls are made to the failing endpoint.
- Packets are handled according to `fail_on_unavailable` (dropped or sent free).
- Backoff starts at **1 second** and doubles up to a maximum of **5 minutes**.
- Backoff resets on the next successful response.

This prevents HPR from hammering a broken endpoint and adding latency to every packet.

## Running Your Own Multi Buy Service

The Multi Buy Service is a standalone Rust application. Source: [multibuy-service](https://github.com/helium/multibuy-service).

The service exposes a single gRPC RPC (`MultiBuy.inc`). Each request includes:

- `key` — hex-encoded packet hash identifying the unique uplink
- `hotspot_key` — base58-encoded public key of the hotspot that received the packet
- `region` — the LoRaWAN region the hotspot is operating in (e.g. `US915`, `EU868`)

The service atomically increments an in-memory counter for the key and returns the current `count` along with a `denied` flag. A background task periodically evicts expired entries.

The [multibuy-service](https://github.com/helium/multibuy-service) repository includes an example of deny list support, where requests from specific hotspots or regions can be rejected. Denied requests still increment the counter (consuming a copy slot) but return `denied: true`, causing HPR to drop the packet. Because each request carries the hotspot key and region, the service can make per-hotspot and per-region decisions.

### Deployment considerations

- Run the service **close to your HPR instances** to minimize latency. Every uplink packet makes a round-trip to the Multi Buy Service.
- The service is stateless beyond its in-memory cache — no database, no persistence. Restarting it just resets counters, which means a brief window where duplicate packets might be purchased (same as the fail-open behavior).
- The gRPC timeout is 5 seconds (matching the LoRaWAN RX window), so the service should respond well under that.