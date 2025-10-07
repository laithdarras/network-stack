## Project 1: Neighbor Discovery (ND) and Flooding Discussion Questions

1. Pros and cons of event-driven programming
   Event-driven code runs only when something happens (a timer fires or a packet arrives), which saves saves CPU so that TinyOS can sleep between events. The downside is that logic is split across small handlers, so following state across events can be harder, and long work must be broken into smaller steps to avoid blocking other events.

2. Why use both flooding duplicate checks and TTL?
   Duplicate checks stop a packet from being forwarded again once a node has seen it. TTL makes the packet expire after a fixed number of hops, even if duplicate state is missing. With only duplicate checks, a cache miss could allow loops causing network congestion. On the other hand, with only TTL, the same packet would be forwarded many extra times until TTL hits zero, wasting bandwidth.

3. Best vs worst case total packets with flooding
   Best case is a line topology where each node has at most two neighbors and we never send back to the neighbor we received the packet from. The packet is forwarded about once per hop toward the destination. Worst case is a dense topology where many neighbors forward at once, and total transmissions grow quickly as the packet fans out until duplicate checks and TTL stop it.

4. Better multi-hop than pure flooding using ND
   Use ND’s neighbor table to choose a single next hop instead of sending to all neighbors. For example, pick the neighbor with better link quality or one that moves the packet closer to the destination. This reduces network congestion compared to flooding.

5. A design decision I could change
   I used arrays for simplicity for smaller networks. An alternative is a hashmap for O(1) lookups, which can help at larger scale. The tradeoff is added wiring and complexity in TinyOS. However, for this project size, arrays kept the code clear and worked well.
