# Project 3: Reliable Transport and Congestion Control

## 1. Introduction

This project implements a TCP-like reliable transport layer on TinyOS/TOSSIM, building on Projects 1-2 (ND, Flooding, Link-State routing). The transport layer adds reliability, flow control, and congestion control on top of best-effort packet delivery.

**Features**: 3-way handshake, Go-Back-N sliding window, retransmission timers, flow control via advertised windows, TCP Tahoe-style congestion control (slow start + AIMD), FIN teardown, multiple concurrent connections.

## 2. Architecture

**Transport Layer**:

- `Transport.h`: TCP header (`tcp_header_t`) with ports, seq, ack, flags, advWindow, dataLen
- `TransportP.nc`: Core implementation (socket control blocks, state machine, buffers, retransmission, congestion control)
- `TransportC.nc`: Wiring to Packet, SimpleSend, Timer interfaces

**Integration**: `Node.nc` routes `PROTOCOL_TCP` packets to `Transport.receive()`, forwards others via Link-State. Testing purposes implements server/client using Socket API methods.

**Data Flow**: Application > `Transport.write()` > `trySendData()` > `sendSegment()` > Link-State routing → Radio. Reverse: Radio > `Transport.receive()` > `handleSegmentForSocket()` > `Transport.read()` > Application.

## 3. Data Structures

**Socket Control Block (`socket_cb_t`)**:

- Connection: `state` (10 TCP states), 4-tuple (local/remote addr/port), `iss`/`irs`, `sndNext`/`rcvNext`
- Send: `sendBuf[128]` (circular), `lastByteWritten`/`lastByteSent`/`lastByteAcked`, `remoteAdvWindow`
- Receive: `recvBuf[128]` (circular), `nextByteExpected`, `lastByteRead`, `advWindow`
- Congestion: `cwnd`, `ssthresh`
- Teardown: `finInFlight`, `finSeq`, `finReceived`, `timeWaitStart`

**Retransmission Queue**: Array of `retrans_entry_t` (fd, seqStart, len, timeoutAt). Single shared `RetransTimer` tracks earliest timeout.

## 4. Connection Management

**3-Way Handshake**:

- Client: `connect()` -> `startClientHandshake()` sends SYN (`iss=0`), waits for SYN+ACK, sends ACK, transitions to an ESTABLISHED connection.
- Server: `listen()` on port, on SYN allocates new socket, sends SYN+ACK (`iss=100`), on ACK transitions to an ESTABLISHED connection. `accept()` returns established socket.

**Teardown**: `close()` sends FIN, enters FIN_WAIT_1 > FIN_WAIT_2 > TIME_WAIT (5s timeout). Passive close: CLOSE_WAIT > LAST_ACK > CLOSED. FIN segments are retransmitted if lost.

## 5. Reliable Data Transfer

**Send Side**:

- `Transport.write()`: Copies app data into `sendBuf` circularly, updates `lastByteWritten`, calls `trySendData()`.
- `trySendData()`: While `lastByteSent < lastByteWritten` and `inFlight < effectiveWindow`, sends segments up to MSS (4 bytes), enqueues retrans entries, updates `lastByteSent`.

**Receive Side (Go-Back-N)**:

- Only accepts in-order segments (`seqNum == nextByteExpected`), copies into `recvBuf` circularly, advances `nextByteExpected`.
- Drops duplicates (`seqNum < nextByteExpected`) and out-of-order (`seqNum > nextByteExpected`), but always sends cumulative ACK with `ack = nextByteExpected`.

**Retransmission**: On timeout, if segment unACKed, resets `lastByteSent = lastByteAcked` (Go-Back-N), adjusts congestion control, retransmits all unACKed data. ACKs remove fully-ACKed retrans entries.

## 6. Flow Control

Receiver computes `advWindow = RECV_BUF_SIZE - used` (where `used = (nextByteExpected - 1) - lastByteRead`), includes in every outgoing segment. Sender uses `effectiveWindow = min(cwnd, remoteAdvWindow, SEND_BUF_SIZE)`, limits `inFlight < effectiveWindow`. This ultimately prevents fast sender from overwhelming slow receiver.

## 7. Congestion Control

**TCP Tahoe-style**:

- Initialization: `cwnd = TCP_MSS` (4), `ssthresh = 4 * TCP_MSS` (16).
- Slow Start (`cwnd < ssthresh`): On ACK of new data, `cwnd += TCP_MSS` (exponential growth).
- Congestion Avoidance (`cwnd >= ssthresh`): On ACK, `cwnd += 1` (linear growth, approximates +1 MSS per RTT).
- On Timeout: `ssthresh = max(cwnd/2, TCP_MSS)`, `cwnd = TCP_MSS` (multiplicative decrease, back to slow start).

**Effective Window**: `min(cwnd, remoteAdvWindow, SEND_BUF_SIZE)` limits sending. ACK clocking: new segments sent as ACKs free space in congestion window.

## 8. Testing

**Test Scripts**:

- `testA.py`: Single client, no noise (`tuna-melt.topo`)
- `testB.py`: Single client, heavy noise (`pizza.topo`, `meyer-heavy.txt`)
- `testCC.py`: Congestion control demonstration (no noise, observe cwnd sawtooth)
- `testMulti.py`: Two concurrent clients (demonstrates multi-connection support)

**Server**: Node 1, port 123. Periodically accepts connections, reads data, prints `Reading Data (fd=X): 0,1,2,3,...` (16-bit integers, in-order).

**Client**: Connects to server, writes 16-bit integers. Logs `Client wrote X bytes` or `Client write throttled` when flow/congestion control limits sending.

**Expected Output**: Server receives monotonically increasing values even under noise. Transport debug channel shows cwnd growth (slow start > congestion avoidance) and drops on timeout.

## 9. Limitations

- Go-Back-N: No selective ACKs, out-of-order segments dropped.
- Fixed RTT: `TCP_TIMEOUT = 1s` (no dynamic RTT estimation).
- Single retrans timer: Shared across all sockets.
- Small buffers: 128 bytes send/recv, 8 sockets max, 16 retrans entries max.
- Small MSS: 4 bytes (due to 20-byte packet payload limit).
- Tahoe-style: No fast retransmit/recovery (TCP Reno).