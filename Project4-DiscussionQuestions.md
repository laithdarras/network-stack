# Project 4 Discussion Questions

1. The chat client and server application, as described above, uses a single transport connection in each direction per client. A different design would use a transport connection per command and reply. Describe the pros and cons of these two designs.

- Persistent (what we implemented):
  - Pros: lower overhead (one handshake per client), preserves user state (username, partial lines) and less manual work with timers.
  - Cons: server must manage per-client state and clean up on disconnect; a stuck connection can hold resources.
- Per-command (new connection for each request/reply):
  - Pros: simpler server state (stateless per request).
  - Cons: high overhead (handshake per command), more sockets, higher latency and more timer load.

2. Describe which features of your transport protocol are a good fit for the chat client and server application, and which are not. Are the features that are not a good fit simply unnecessary, or are they problematic, and why? If problematic, how can we best deal with them?

- Good fit: reliable, in-order delivery, flow/congestion control, multi-connection support, CRLF line framing on top of a stream works well.
- Less useful/problematic: per-byte congestion control logs are noisy for small chat lines and small MSS (4 bytes) causes many segments per line which adds overhead but still works due to reliability. Best mitigation: keep messages short (as we do) and accept the overhead.

3. Read the HTTP protocol specification. Describe which features of your transport protocol are a good fit for the web server application, and which are not. Are the features that are not a good fit simply unnecessary, or are they problematic, and why? If problematic, how can we best deal with them?

- Good fit: reliable, in-order stream, supports request/response, flow/congestion control.
- Less useful/problematic: tiny MSS (4 bytes) makes HTTP inefficient, Tahoe without fast retransmit hurts performance on larger objects. Best mitigation: keep objects small and accept multiple RTTs.

4. Design improvement

- Add a tiny content cache (or reuse connections) for repeated GETs like a web proxy/CDN: if the same resource is requested again, serve it from cache over the existing connection to reduce retransmits and handshakes.