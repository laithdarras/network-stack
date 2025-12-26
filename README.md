# Network Stack

An end-to-end, layered network stack implemented in TinyOS/TOSSIM, spanning
neighbor discovery and flooding, link-state routing, reliable transport with
congestion control, and a client–server chat application.

This project emphasizes protocol correctness, layering, and observability under
lossy, multi-hop network conditions.

---

## What This Demonstrates

- Design and implementation of a **layered network stack**
- Distributed routing using **link-state advertisements and Dijkstra**
- **Reliable transport** with flow control and congestion control
- Protocol behavior under **loss, delay, and reordering**
- Debugging and validation via **event-level instrumentation**

---

## Background

The TCP/IP protocol stack organizes networking functionality into layers with clear responsibilities. In this project, the link layer discovers and maintains local neighbors, the network layer computes multi-hop routes using link-state routing, the transport layer provides reliable, congestion-controlled byte streams, and the application layer implements a client–server chat protocol on top of reliable transport.

Key concepts implemented:

**Physical Layer (TOSSIM)**:

- **TOSSIM Radio**: Simulated physical layer that models radio hardware for testing in software without real hardware

**Link Layer (Neighbor Discovery and Flooding)**:

- **Neighbor Discovery**: Periodic REQ/REP messages to discover direct (1-hop) neighbors
- **Link Quality Estimation**: Track REQ/REP success rate to estimate link reliability
- **Flooding**: Multi-hop delivery via per-link unicast
- **TTL-based Termination**: Hop limit prevents infinite loops

**Network Layer (Link-State Routing)**:

- **Link-State Advertisements (LSAs)**: Information containing the topology distributed via flooding
- **Link-State Database (LSDB)**: A view of the entire network topology at each node
- **Dijkstra's Algorithm**: Shortest path computation from each node to all other nodes
- **Routing Table**: `nextHop[]` and `dist[]` arrays for efficient packet forwarding

**Transport Layer (TCP-Like Reliable Transport)**:

- **Sequence numbers and ACKs**: Cumulative acknowledgments for reliable delivery
- **Retransmission timers**: Timeout-based loss detection and recovery
- **Sliding window**: Transmission of segments
- **Flow control**: Preventing the sender from overwhelming the receiver
- **Congestion control**: Preventing the sender from overwhelming the network
- **Connection management**: 3-way handshake and setup/teardown
- **Multi-connection support**: Concurrent sockets with independent states

**Application Layer (Chat Client/Server)**:

- **Text-based protocol**: CRLF-terminated commands (hello, msg, whisper, listusr)
- **Concurrent clients**: Server handles up to 8 simultaneous connections
- **Command parsing**: String-based protocol over reliable byte stream

---

## How to Run

### Prerequisites

- TinyOS 2.x development environment
- Python 2.7 (for TOSSIM)
- `nescc` compiler (part of TinyOS toolchain)

### Build

```bash
make micaz sim
```

This compiles the nesC code and generates Python bindings for TOSSIM integration. The `micaz sim` target builds for TOSSIM.

### Run a Simulation

```bash
python2 testA.py
```

This runs a single-client transport test: node 4 connects to server at node 1, sends 1000 16-bit integers, server receives and prints them in-order.

**Note**: Use `python2` (not `python`) as TOSSIM requires Python 2.7.

### Test Scripts

- `testA.py`: Single client, no noise (tests transport reliability)
- `testB.py`: Single client, heavy noise (tests retransmission under loss)
- `testCC.py`: Congestion control visualization (observe cwnd sawtooth)
- `testMulti.py`: Two concurrent clients (tests multi-connection support)
- `TestSim.py`: Chat application demo (two clients: alice, bob)
- `pingTest.py`: Basic ping test (tests ND and routing)

### Various Network Conditions

**Enable Loss/Delay/Reordering**:

- **Loss**: Use `s.loadNoise("meyer-heavy.txt")` instead of `"no_noise.txt"` in test scripts
- **Delay**: Inherent in multi-hop routing; adjust topology in `topo/*.topo` files

**Topology Files** (`topo/`):

- `long_line.topo`: 19-node linear chain with ring closure (tests multi-hop routing)
- `tuna-melt.topo`: Mesh topology (tests routing convergence)
- `pizza.topo`: Complex topology

**Noise Files** (`noise/`):

- `no_noise.txt`: Zero packet loss
- `meyer-heavy.txt`: High packet loss rate

### Command Injections

Test scripts inject commands via `CommandHandler`:

- `s.ping(src, dest, msg)`: Send ping (tests ND and routing)
- `s.neighborDMP(node)`: Dump neighbor table
- `s.routeDMP(node)`: Dump routing table
- `s.testServer(node)`: Start transport server
- `s.testClient(node)`: Start transport client
- `s.chatHello(node, username, port)`: Start chat client
- `s.chatMsg(node, msg)`: Send chat message
- `s.chatWhisper(node, target, msg)`: Send whisper
- `s.chatListUsr(node)`: Request user list

---

## Output

The system displays behavior through debug channels. Each channel can be enabled/disabled in test scripts via `s.addChannel(channelName)`.

**Neighbor Discovery Events**:

- REQ/REP transmission and reception
- Neighbor table updates (new neighbors, aging out)
- Link quality metrics (REQ sent, REP received, percentage)

**Flooding Events**:

- Packet forwarding decisions
- Duplicate detection and drops
- TTL expiration

**Link-State Routing Events**:

- LSA generation: `LS: Timer fired, building new LSA`
- LSA flooding: `LS: Flooding LSA from <node> seq=<s> n=<k>`
- LSA reception: `LSA received from <origin> (seq=<s>)`
- LSDB updates: `LS: LSDB updated for origin=<id> count=<n> (seq=<s>)`
- Route computation: `LS: Recomputing routes`
- Next-hop lookups: `LS: nextHop returned <node> for dst <dest>`

**Transport Channel Events**:

- Connection lifecycle: `SYN sent`, `SYN received`, `ESTABLISHED`, `FIN sent`, `TIME_WAIT`
- Data transfer: `Client wrote X bytes`, `write: no space` (flow control), `Reading Data (fd=X): values`
- Congestion control: `cwnd` changes, timeout events, retransmission
- Flow control: `write throttled`, `advWindow` values

**Chat Channel Events**:

- Client: `connected to server`, `sendMsg`, `sendWhisper`, `recv: msgFrom`, `listUsrRply`
- Server: `listening on port`, `accepted fd`, `user joined`, `broadcast`, `whisper`

**Metrics Tracked**:

- **ND**: Per-neighbor link quality, active neighbor count, missed REQ periods
- **LS**: LSDB size, route table entries, next-hop cache hits/misses
- **Transport**: Per-socket `lastByteWritten`, `lastByteSent`, `lastByteAcked`, `inFlight`, `cwnd`, `ssthresh`, `advWindow`
- **Chat**: Active client count, messages sent/received per client

---

## Correctness Guarantees

**Link Layer**:

1. **Neighbor Discovery**: All direct neighbors are eventually discovered and maintained in table
2. **Link Quality**: Link quality metrics accurately reflect REQ/REP success rate
3. **Flooding**: All nodes in connected component receive flooded packets (bounded by TTL)
4. **Duplicate Suppression**: No packet is forwarded twice by the same node
5. **TTL Termination**: Packets eventually expire even if duplicate cache fails

**Network Layer**:

1. **LSDB Consistency**: All nodes eventually have consistent view of topology (after convergence)
2. **Route Correctness**: `nextHop[dest]` points to valid neighbor on shortest path to destination
3. **Bidirectional Links**: Only bidirectional links are used in routing computation
4. **Route Convergence**: Routes converge after topology changes (LSA propagation + Dijkstra recomputation)
5. **Fallback to Flooding**: Packets with no route fall back to flooding

**Transport Layer**:

1. **In-order delivery**: Server receives monotonically increasing sequence numbers even under loss
2. **No data loss**: All application bytes are eventually delivered (bounded by retransmission limit)
3. **Connection integrity**: State machine transitions are valid
4. **Flow control**: Sender never exceeds `remoteAdvWindow`, receiver never overflows buffer
5. **Congestion control**: `cwnd` converges; sawtooth pattern under loss

**Application Layer**:

1. **Command Parsing**: All CRLF-terminated commands are correctly parsed
2. **Concurrent Clients**: Up to 8 clients can connect simultaneously without interference
3. **Message Delivery**: Broadcast messages reach all connected clients; whispers reach only target
4. **User List**: `listusr` returns accurate, comma-separated list of active users

---

## Known Limitations

**Link Layer**:

- **Array-based tables**: Fixed-size neighbor table (10 max) limits scalability
- **No link cost**: Unit-cost routing (all links cost 1), no signal strength-based routing
- **Simple aging**: Period-based aging may be too aggressive or too lenient depending on network dynamics

**Network Layer**:

- **No route caching**: Routes recomputed on every LSA update (could cache stable routes)
- **Unit-cost only**: All links have cost 1; no weighted shortest paths
- **LSDB size limit**: 20 nodes max; larger networks require refactoring

**Transport Layer**:

- **Go-Back-N**: Out-of-order segments are dropped (no selective ACK). High loss rates cause inefficient retransmission.
- **Fixed RTT**: `TCP_TIMEOUT = 1s` is fixed; no dynamic RTT estimation.
- **Small buffers**: 128-byte send/recv buffers, 8 sockets max, 16 retrans entries max (resource constraints).
- **Small MSS**: 4-byte maximum segment size (due to 28-byte packet payload limit in TOSSIM).
- **TCP Tahoe**: No fast retransmit/recovery (TCP Reno).

**Application Layer**:

- **No disconnect handling**: Client disconnects not detected; server may hold stale client entries