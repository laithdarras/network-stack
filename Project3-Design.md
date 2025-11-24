## Project 3: Reliable Transport

1. Our current network provides delivery of packets to nodes using using Dijkstra and LSAs, but it has no guarantee of
no loss, no duplicates, no reordering, no protection against too-fast sender overwhelming a slow-receiver. Project 3 in TCP is handling this messy stuff.
2. Need to add reliability and sliding window + flow control via ADV WIN on top of TCP protocol
a. Handle loss
- Use sequence numbers, ACKs, and timeouts.
- Keep a queue of sent-but-not-yet-ACKed segments with timeout = now + 2*RTT.
- On timeout -> retransmit. 

b. Handle duplicates
- Track nextByteExpected.
- If a segment’s seq < nextByteExpected -> it’s a duplicate, drop it but still ACK.

c. Handle reordering (Go-Back-N) for sliding window implementation using the gobackn protocol.
- Only accept in-order data (seq == nextByteExpected).
- Anything > nextByteExpected is ignored until the missing piece is retransmitted.
- ACK always advertises the next in-order byte (cumulative ACK). 
d. Handle flow control (avoid fast sender/slow receiver)
- Receiver computes advertised window from its recv buffer and puts it in the header. 
- Sender uses:
    - effectiveWindow = min(SEND_BUF_SIZE, remoteAdvWindow)
    - canSend = (lastByteSent - lastByteAcked) < effectiveWindow
- So a fast sender cannot send past what the receiver says it can buffer.
The send buffer and receive buffer needs to follow the

- Congestion control, we need to incorporate ACK clocking, and counteract congestion with AIMD + Slow Start. 

Need to implement additionally:
- State machine scenarios for closures, stop and wait, sending/receiving is done but still need to complete closing the connection. close the connection officially from state machine. 
- Need to implement the TCP states with an enum including all the states of a TCP connection