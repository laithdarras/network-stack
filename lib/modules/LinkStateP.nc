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
      call lsaTimer.startPeriodic(5000);
      dbg(GENERAL_CHANNEL, "LS: Started\n");
   }

   command void LinkState.stop() {
      running = FALSE;
      call lsaTimer.stop();
      dbg(GENERAL_CHANNEL, "LS: Stopped\n");
   }

   command void LinkState.recomputeRoutes() {
      // Stub: to be implemented with Dijkstra later
   }

   // Periodic LSA
   event void lsaTimer.fired() {
      pack msg;
      uint8_t ok;
      uint16_t plen = 0;
      uint8_t neighborCount;

      if (!running) return;

      ok = buildLsaPayload((uint8_t*)msg.payload, &plen);
      if (!ok) {
         return;
      }

      msg.src = TOS_NODE_ID;
      msg.dest = 0xFFFF;
      msg.seq = localSeq; // also used by Flooding for dedup
      msg.TTL = MAX_TTL;
      msg.protocol = LS_PROTOCOL; // Link-State protocol ID 4

      // Extract neighbor count from payload (after LSA tag, at offset 4 in lsa_msg_t)
      neighborCount = msg.payload[LSA_TAG_LEN + 4];
      call Flooding.send(msg, 0xFFFF);
      dbg(GENERAL_CHANNEL, "LS: Sent LSA seq=%d n=%d\n", localSeq, neighborCount);
   }

   // Receive Flooding packets and filter LSAs
   event void Flooding.receive(pack pkt, uint16_t from) {
      lsa_msg_t lsa;
      LinkStateEntry* e;
      if (!running) return;
      if (pkt.protocol != LS_PROTOCOL) return;
      if (pkt.payload[0] != 'L' || pkt.payload[1] != 'S' || pkt.payload[2] != 'A') return;
      memcpy(&lsa, &pkt.payload[LSA_TAG_LEN], sizeof(lsa_msg_t));

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
         dbg(GENERAL_CHANNEL, "LS: Updated entry for %d seq=%d from %d\n", lsa.origin, lsa.seqno, from);
      }
   }
}


