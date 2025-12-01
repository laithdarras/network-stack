## Project 3: Discussion Questions

### 1. When establishing a new connection, your transport protocol implementation picks an initial sequence number. This might be 1, or it could be a random value. Which is better, and why?

A random value is better for security. Using predictable sequence numbers allows attackers to predict future sequence numbers and attack our system. Random initial sequence numbers make it much harder for attackers to guess the real sequence numbers.

### 2. Your transport protocol implementation picks the buffer size for received data used as part of flow control. How large should this buffer be, and why?

The buffer size should match the receiver's processing capacity. Too small of a buffer causes frequent flow control stalls when the receiver can't keep up. Too large of a buffer wastes memory if the receiver processes data quickly. Our implementation uses 128 bytes as a reasonable middle ground that balances throughput and memory usage. The optimal size depends on the application's read rate and network conditions.

### 3. Our connection setup protocol is vulnerable to the following attack. The attacker sends a large number of connection requests (SYN) packets to a particular node but never sends any data. (This is called a SYN flood.) What would happen to your implementation if it were attacked in this way? How might you have designed the initial handshake protocol (or the protocol implementation) differently to be more robust to this attack?

In our implementation, each SYN creates a new socket in SYN_RCVD state. With only `MAX_SOCKETS = 8`, an attacker could quickly fill all socket slots which would prevent real connections. The attacker never completes the handshake (no final ACK), so sockets remain in SYN_RCVD indefinitely. A solution to this attack could be to restrict allocating sockets until the final ACK arrives. This way, we could encode a connection state in the SYN+ACK's sequence number. Another possible solution is set a limit on the number of SYN packets from the same source.

### 4. What happens in your implementation when a sender transfers data but never closes a connection? (This is called a FIN attack.) How might we design the protocol differently to better manage this case?

The connection stays in ESTABLISHED state indefinitely, which consumes a socket slot and memory (send/recv buffers). With only 8 sockets max, this prevents new connections. The sender can keep sending data, wasting network resources. A solution to this attack is to periodically check the activity status of each connection and close connections that have no activity. This prevents stale connections and allowing new connections to be initiated.
