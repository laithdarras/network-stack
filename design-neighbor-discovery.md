# Neighbor Discovery and Flooding

## Goals

- Provide multi-hop delivery via Flooding over TinyOS/TOSSIM.
- Maintain connectivity via Neighbor Discovery (ND).
- Constrain overhead and contention using per-link unicast and duplicate suppression.

## Architecture

- Node performs central dispatch on the `protocol` field using `AMPacket.source` for inbound identity. This isolates receive logic and simplifies wiring.
- ND maintains a neighbor table (activity, link quality, aging) to reflect usable links. Flooding consumes this table to select outgoing links.
- Flooding implements wired flooding (per-link unicast except inbound) to bound interference and give control of transmissions.

## Packets

- Header: `{src, dest, seq, TTL, protocol, payload[]}`.
  - `src+seq` enable duplicate suppression.
  - `TTL` bounds lifetime and guarantees termination.
  - `protocol` routes packets to ND or Flooding without extra parsing.

## Neighbor Discovery

- Periodic REQ/REP messages maintain liveness with minimal control traffic.
- Fixed-size array table is deterministic and adequate for small ND sets; fields: `addr`, `active`, counters for a link-quality estimate, `missedCount` for period-based aging.
- Period-based aging (missed-beacon threshold) is robust to timer granularity and avoids wall-clock tuning.

## Flooding

- Duplicate cache (max `seq` per `src`) prevents circulation and bounds processing.
- TTL enforces eventual termination independent of cache state.
- Per-link unicast to all active neighbors except inbound satisfies wired flooding.
- Synchronous `SimpleSend` eliminates concurrency concerns.

## Key decisions

- Array-based tables: predictable memory and constant factors; sufficient for ND/Flooding scale in this project.
- Central receive in `Node`: single routing point based on `protocol` reduces duplication and miswiring risks.

## Testing

- Line topology demonstrates controlled multi-hop propagation and TTL expiration across many hops.
- Command-driven tests (`ping`, `neighborDMP`) validate end-to-end delivery and ND table population under TOSSIM.

## Limitations and Next Steps

- No next-hop routing yet. Next, leverage ND to select a single next hop instead of flooding; this is the basis for Project 2 (Routing).
- Data structure scalability. If neighbor or duplicate tables grow, refactor arrays to the provided hash map to reduce lookup cost and improve scalability.
- Reliability controls. Add retransmissions and basic congestion control to improve performance under loss or high contention.

## Definitions

- ND (Neighbor Discovery): Periodic REQ/REP to learn and maintain a neighbor table (addr, active, simple link quality, aging).
- Flooding: Per-link unicast to all active neighbors except the inbound one, with duplicate suppression and TTL.
- TTL (Time-To-Live): Hop limit; packet is dropped at 0 to prevent loops.
- Duplicate cache: Max sequence number seen per source; older or equal seq is dropped.
- AMPacket: Interface to read the link-layer sender for correct inbound filtering.