## Project 2: Discussion Questions

### 1. Why do we use a link for the shortest path computation only if it exists in our database in both directions? What would happen if we used a directed link AB when the link BA does not exist?

We only use a link if it exists in both directions to avoid picking paths that cannot actually carry data end‑to‑end. If A can reach B but B cannot reach A, then packets will fail, which ultimately breaks our network. Treating links as bidirectional makes sure the graph reflects usable connectivity, making path costs meaningful and paths reliable.

### 2. Does your routing algorithm produce symmetric routes (that follow the same path from X to Y in reverse when going from Y to X)? Why or why not?

Routes are not necessarily symmetric. Link‑state computes shortest paths independently from each source using the current graph and costs, so X -> Y may pick a different path than Y -> X if costs or available links differ. Even with costs being the same, transient LSDB differences or tie‑breaks can produce asymmetric results.

### 3. What would happen if a node advertised itself as having neighbors, but never forwarded packets? How might you modify your implementation to deal with this case?

If a node produced a false-positive that advertises connectivity but fails to forward, then traffic routed through it will be dropped. The topology will look valid, so shortest paths may still target the faulty node. A simple mitigation is to add some edge cases (e.g., periodic probes or passive loss metrics) and penalize links that fail to carry traffic.

### 4. What happens if link-state packets are lost or corrupted?

Losing or corrupting LSAs can cause stale or incomplete LSDBs, leading to suboptimal or incorrect routes. Sequence numbers prevent older information from overriding newer state, and periodic reflooding heals gaps over time.

### 5. What would happen if a node alternated between advertising and withdrawing a neighbor, every few milliseconds? How might you modify your implementation to deal with this case?

A node constantly alternating between advertising and withdrawing a neighbor would make the topology unstable. This triggers frequent recomputations and route changes, which can increase loss and latency. To mitigate this, I can make it so that a link is required to be consistently present for some time before advertising it, or consistently absent before withdrawing it. This would reduce withdrawals and promote convergence of the algorithm.
