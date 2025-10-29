#include <Timer.h>
#include "../../includes/packet.h"
#include "../../includes/channels.h"

enum {
   MAX_NEIGHBORS_LS = 10,   // Keep consistent with ND
   MAX_NODES = 20,           // Maximum nodes in network
   LSA_TAG_LEN = 3,
   LS_PROTOCOL = 4           // Link-State protocol ID
};

typedef struct {
   uint16_t nodeID;
   uint16_t seqno;
   uint8_t neighborCount;
   uint16_t neighbors[MAX_NEIGHBORS_LS];
} LinkStateEntry;

// Payload format: "LSA" + lsa_msg_t
typedef nx_struct lsa_msg_t {
   nx_uint16_t origin;
   nx_uint16_t seqno;
   nx_uint8_t neighborCount;
   nx_uint16_t neighbors[MAX_NEIGHBORS_LS];
} lsa_msg_t;

module LinkStateP {
   uses {
      interface Flooding;
      interface NeighborDiscovery;
      interface Timer<TMilli> as lsaTimer;
   }
   provides interface LinkState;
}

implementation {
   // Simple LS database keyed by nodeID with latest seqno
   LinkStateEntry lsdb[MAX_NODES];
   uint8_t lsdbCount = 0;
   uint16_t localSeq = 0;
   bool running = FALSE;

   // Routing structures for Dijkstra
   #define INF 9999
   #define INVALID_NODE 0xFFFF
   uint16_t cost[MAX_NODES][MAX_NODES];
   uint16_t dist[MAX_NODES];
   uint16_t prev[MAX_NODES];
   uint16_t nextHop[MAX_NODES];

   // Forward declarations
   void computeRoutes();
   void updateLocalLsdbFromND();

   // Find or create entry by nodeID
   LinkStateEntry* findEntry(uint16_t nodeID) {
      uint8_t i;
      for (i = 0; i < lsdbCount; i++) {
         if (lsdb[i].nodeID == nodeID) return &lsdb[i];
      }
      if (lsdbCount < MAX_NODES) {
         lsdb[lsdbCount].nodeID = nodeID;
         lsdb[lsdbCount].seqno = 0;
         lsdb[lsdbCount].neighborCount = 0;
         return &lsdb[lsdbCount++];
      }
      return NULL;
   }

   // Build LSA from ND table into payload buffer
   uint8_t buildLsaPayload(uint8_t* outBuf, uint16_t* outLen) {
      uint8_t i, count;
      lsa_msg_t lsa;
      // Tag
      outBuf[0] = 'L'; outBuf[1] = 'S'; outBuf[2] = 'A';

      lsa.origin = TOS_NODE_ID;
      lsa.seqno = ++localSeq;
      lsa.neighborCount = 0;

      count = call NeighborDiscovery.getNeighborCount();
      for (i = 0; i < count && lsa.neighborCount < MAX_NEIGHBORS_LS; i++) {
         uint16_t addr; bool active;
         if (call NeighborDiscovery.getNeighbor(i, &addr, &active) && active) {
            lsa.neighbors[lsa.neighborCount++] = addr;
         }
      }

      // Copy struct after tag
      if ((sizeof(lsa_msg_t) + LSA_TAG_LEN) > PACKET_MAX_PAYLOAD_SIZE) {
         return 0;
      }
      memcpy(&outBuf[LSA_TAG_LEN], &lsa, sizeof(lsa_msg_t));
      *outLen = LSA_TAG_LEN + sizeof(lsa_msg_t);
      return 1;
   }

   // Start/Stop
   command void LinkState.start() {
      running = TRUE;
      lsdbCount = 0;
      localSeq = 0;
      {
         uint16_t i;
         for (i = 0; i < MAX_NODES; i++) {
            dist[i] = INF;
            prev[i] = INF;
            nextHop[i] = INF;
         }
      }
      call lsaTimer.startPeriodic(5000);
      dbg(GENERAL_CHANNEL, "LS: Booted, starting periodic LSA flooding\n");

      // Proactively advertise once at startup so LSDBs populate early
      {
         pack msg;
         uint8_t ok;
         uint16_t plen = 0;
         uint8_t neighborCount;
         updateLocalLsdbFromND();
         ok = buildLsaPayload((uint8_t*)msg.payload, &plen);
         if (ok) {
            msg.src = TOS_NODE_ID;
            msg.dest = 0xFFFF;
            msg.seq = localSeq;
            msg.TTL = MAX_TTL;
            msg.protocol = 3; // flood
            neighborCount = msg.payload[LSA_TAG_LEN + 4];
            call Flooding.send(msg, 0xFFFF);
            dbg(GENERAL_CHANNEL, "LS: Sent initial LSA seq=%d n=%d\n", localSeq, neighborCount);
         }
      }
   }

   command void LinkState.stop() {
      running = FALSE;
      call lsaTimer.stop();
      dbg(GENERAL_CHANNEL, "LS: Stopped\n");
   }

   command void LinkState.recomputeRoutes() {
      dbg(GENERAL_CHANNEL, "LS: Recomputing routes\n");
      computeRoutes();
      call LinkState.printRouteTable();
   }

   // Periodic LSA
   event void lsaTimer.fired() {
      pack msg;
      uint8_t ok;
      uint16_t plen = 0;
      uint8_t neighborCount;

      if (!running) return;

      dbg(GENERAL_CHANNEL, "LS: Timer fired, building new LSA\n");

      // Refresh our own LSDB entry from current ND table
      updateLocalLsdbFromND();

      ok = buildLsaPayload((uint8_t*)msg.payload, &plen);
      if (!ok) {
         return;
      }

      msg.src = TOS_NODE_ID;
      msg.dest = 0xFFFF;
      msg.seq = localSeq; // also used by Flooding for dedup
      msg.TTL = MAX_TTL;
      msg.protocol = 3; // Use Flooding protocol to disseminate LSAs

      // Extract neighbor count from payload (after LSA tag, at offset 4 in lsa_msg_t)
      neighborCount = msg.payload[LSA_TAG_LEN + 4];
      dbg(GENERAL_CHANNEL, "LS: Flooding LSA from %d seq=%d n=%d\n", TOS_NODE_ID, localSeq, neighborCount);
      call Flooding.send(msg, 0xFFFF);
      dbg(GENERAL_CHANNEL, "LS: Sent LSA seq=%d n=%d\n", localSeq, neighborCount);
   }

   // Receive Flooding packets and filter LSAs
   event void Flooding.receive(pack pkt, uint16_t from) {
      lsa_msg_t lsa;
      LinkStateEntry* e;
      if (!running) return;
      if (pkt.protocol != 3) return; // Only process LSAs carried via flooding
      if (pkt.payload[0] != 'L' || pkt.payload[1] != 'S' || pkt.payload[2] != 'A') return;
      memcpy(&lsa, &pkt.payload[LSA_TAG_LEN], sizeof(lsa_msg_t));
      dbg(GENERAL_CHANNEL, "LSA received from %d (seq=%d)\n", lsa.origin, lsa.seqno);

      e = findEntry(lsa.origin);
      if (e == NULL) {
         // Create new entry if not found and table not full
         if (lsdbCount < MAX_NODES) {
            e = &lsdb[lsdbCount];
            e->nodeID = lsa.origin;
            e->seqno = 0;
            e->neighborCount = 0;
            lsdbCount++;
         } else {
            return; // Table full, cannot add new entry
         }
      }
      if (lsa.seqno > e->seqno) {
         uint8_t i;
         e->seqno = lsa.seqno;
         e->neighborCount = lsa.neighborCount;
         if (e->neighborCount > MAX_NEIGHBORS_LS) e->neighborCount = MAX_NEIGHBORS_LS;
         for (i = 0; i < e->neighborCount; i++) {
            e->neighbors[i] = lsa.neighbors[i];
         }
         dbg(GENERAL_CHANNEL, "LS: LSDB updated for origin=%d count=%d (seq=%d)\n", lsa.origin, e->neighborCount, lsa.seqno);
         dbg(GENERAL_CHANNEL, "LS: Updated entry for %d seq=%d from %d\n", lsa.origin, lsa.seqno, from);

         // Recompute routes on any update
         computeRoutes();
         call LinkState.printRouteTable();
      }
   }


   // Build the adjacency cost matrix from the LSDB and run Dijkstra
   void computeRoutes() {
   uint16_t src;
   uint16_t i;
   uint16_t j;
   bool visited[MAX_NODES];

   // Initialize cost matrix and vectors
   for (i = 0; i < MAX_NODES; i++) {
      for (j = 0; j < MAX_NODES; j++) {
         cost[i][j] = (i == j) ? 0 : INF;
      }
      dist[i] = INF;
      prev[i] = INF;
      nextHop[i] = INF;
      visited[i] = FALSE;
   }

   // Populate cost from LSDB entries
   for (i = 0; i < lsdbCount; i++) {
      uint16_t u = lsdb[i].nodeID;
      uint8_t k;
      if (u >= MAX_NODES) continue;
      for (k = 0; k < lsdb[i].neighborCount; k++) {
         uint16_t v = lsdb[i].neighbors[k];
         if (v >= MAX_NODES) continue;
         cost[u][v] = 1;
         cost[v][u] = 1;
      }
   }

   src = TOS_NODE_ID;
   if (src >= MAX_NODES) return;

   // Dijkstra initialization
   dist[src] = 0;
   prev[src] = src;

   // Dijkstra main loop
   for (i = 0; i < MAX_NODES; i++) {
      uint16_t u = INF;
      uint16_t minDist = INF;
      // pick unvisited with smallest dist
      for (j = 0; j < MAX_NODES; j++) {
         if (!visited[j] && dist[j] < minDist) {
            minDist = dist[j];
            u = j;
         }
      }
      if (u == INF) break; // no more reachable
      visited[u] = TRUE;

      // Relax edges from u
      for (j = 0; j < MAX_NODES; j++) {
         uint16_t w = cost[u][j];
         if (w >= INF) continue;
         if (dist[u] + w < dist[j]) {
            dist[j] = dist[u] + w;
            prev[j] = u;
         }
      }
   }
   // finished computing distances and predecessors

   // Compute nextHop for each destination by following prev chain
   for (i = 0; i < MAX_NODES; i++) {
      uint16_t cur;
      uint16_t step;
      if (i == src) continue;
      if (dist[i] >= INF) {
         nextHop[i] = INF;
         continue;
      }
      cur = i;
      step = i;
      // Walk back until the predecessor is src
      while (prev[step] != src && prev[step] != step && prev[step] < INF) {
         step = prev[step];
      }
      if (prev[step] == src) {
         nextHop[i] = step;
      } else if (prev[i] == src) {
         nextHop[i] = i;
      } else {
         nextHop[i] = INF;
      }
   }
   }

   // Debugging: print the routing table
   command void LinkState.printRouteTable() {
   uint16_t i;
   dbg(GENERAL_CHANNEL, "Routing Table for Node %d\n", TOS_NODE_ID);
   for (i = 0; i < MAX_NODES; i++) {
      if (i != TOS_NODE_ID && nextHop[i] < INF) {
         dbg(GENERAL_CHANNEL, "Dest %d --> NextHop %d (dist=%d)\n", i, nextHop[i], dist[i]);
      }
   }
   }

   command uint16_t LinkState.nextHop(uint16_t dest) {
      if (dest >= MAX_NODES) return INVALID_NODE;
      if (nextHop[dest] >= INF) return INVALID_NODE;
      return nextHop[dest];
   }

   // Update or insert our own LSDB entry from NeighborDiscovery table
   void updateLocalLsdbFromND() {
      LinkStateEntry* e = findEntry(TOS_NODE_ID);
      uint8_t i, count;
      if (e == NULL) {
         if (lsdbCount >= MAX_NODES) return;
         e = &lsdb[lsdbCount++];
         e->nodeID = TOS_NODE_ID;
         e->seqno = 0;
         e->neighborCount = 0;
      }
      e->seqno = localSeq; // reflect latest seq we're about to advertise
      e->neighborCount = 0;
      count = call NeighborDiscovery.getNeighborCount();
      for (i = 0; i < count && e->neighborCount < MAX_NEIGHBORS_LS; i++) {
         uint16_t addr; bool active;
         if (call NeighborDiscovery.getNeighbor(i, &addr, &active) && active) {
            e->neighbors[e->neighborCount++] = addr;
         }
      }
   }
}

