## Link-State Routing

### Overview

This stack implements a link-state routing protocol in TinyOS. It reuses Neighbor Discovery (ND) to learn direct neighbors and Flooding to spread Link-State Advertisements (LSAs). The protocol runs in four phases:

- Neighbor discovery: periodically discover and track active neighbors.
- Link-state flooding: build compact LSAs and distribute them via the Flooding component.
- Dijkstra computation: recompute shortest paths from each node to all others using the LS database (LSDB).
- Packet forwarding: use a routing table (`nextHop[]`, `dist[]`) to forward packets; fallback to flooding when no route exists.

### Design Process

- Started from Project 1’s working ND and Flooding modules and verified they ran under TOSSIM.
- Integrated a new LinkState component (`LinkStateP.nc`/`LinkStateC.nc`) that depends on ND, Flooding, and a timer.
- Incremental bring‑up: (1) compile; (2) confirm ND tables; (3) build LSAs and verify flooding; (4) populate LSDB on receive; (5) recompute routes with Dijkstra and validate routing tables; (6) enable forwarding via `nextHop`.

### Key Design Decisions

- Compact LSA format to fit under `PACKET_MAX_PAYLOAD_SIZE`:
  - Layout: `"LSA" + origin (2) + seqno (2) + count (1) + neighbors[count]*2`.
  - Keeps payload small and avoids fragmentation.
- Use existing Flooding (protocol 3) to spread LSAs instead of introducing a new protocol number.
- Dijkstra recomputes on every LSDB update to reflect the latest topology.
- Routing table stored as static arrays: `dist[MAX_NODES]` and `nextHop[MAX_NODES]` (no malloc).
- Logging:
  - `LS: Timer fired, building new LSA`
  - `LS: Flooding LSA from <node> seq=<s> n=<k>`
  - `LSA received from <origin> (seq=<s>)`
  - `LS: LSDB updated for origin=<id> count=<n> (seq=<s>)`
  - `LS: Recomputing routes`
- Forwarding behavior: pings first consult `LS.nextHop(dest)`; if invalid, fallback to flooding.

### Limitations

- Timing: initial dumps may be empty if taken before the first LSA round; giving the sim a few seconds resolves this.