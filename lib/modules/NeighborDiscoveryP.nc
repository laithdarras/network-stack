#include <Timer.h>
#include "../../includes/packet.h"
#include "../../includes/channels.h"

// Neighbor table entry
typedef struct {
   uint16_t addr;
   bool active;
   uint32_t lastSeen; // unused in missed-count aging but kept for future use
   uint16_t numReqSentTo;
   uint16_t numRepReceivedFrom;
   uint8_t missedCount;      // number of consecutive periods with no activity
   bool recentlySeen;        // set on REQ/REP reception this period
} neighbor_t;

enum {
   MAX_NEIGHBORS = 10,
   ND_REQ_INTERVAL = 2000,  // 2 seconds
   ND_MISS_THRESHOLD = 5,   // age out after ~5 missed periods
   ND_REQ_TYPE = 1,
   ND_REP_TYPE = 2
};

generic module NeighborDiscoveryP() {
   provides interface NeighborDiscovery;

   uses interface Timer<TMilli> as neighborTimer;
   uses interface Timer<TMilli> as ageTimer;
   uses interface SimpleSend as SS;
   uses interface Random;
}

implementation {
   neighbor_t neighbors[MAX_NEIGHBORS];
   uint8_t numNeighbors = 0;
   bool running = FALSE;
   uint16_t reqSeq = 0;

   neighbor_t* findNeighbor(uint16_t addr) {
      uint8_t i;
      for (i = 0; i < numNeighbors; i++) {
         if (neighbors[i].addr == addr) {
            return &neighbors[i];
         }
      }
      return NULL;
   }

   void updateNeighborOnSeen(uint16_t addr) {
      neighbor_t* n = findNeighbor(addr);
      if (n == NULL && numNeighbors < MAX_NEIGHBORS) {
         neighbors[numNeighbors].addr = addr;
         neighbors[numNeighbors].active = TRUE;
         neighbors[numNeighbors].lastSeen = 0;
         neighbors[numNeighbors].numReqSentTo = 0;
         neighbors[numNeighbors].numRepReceivedFrom = 0;
         neighbors[numNeighbors].missedCount = 0;
         neighbors[numNeighbors].recentlySeen = TRUE;
         numNeighbors++;
         dbg(GENERAL_CHANNEL, "ND: Added neighbor %d\n", addr);
      } else if (n != NULL) {
         n->active = TRUE;
         n->recentlySeen = TRUE;
         n->missedCount = 0; // reset on any activity
      }
   }

   void sendNDReq() {
      uint8_t i;
      if (numNeighbors == 0) {
         pack req;
         req.src = TOS_NODE_ID;
         req.dest = 0xFFFF;  // initial discovery
         req.seq = reqSeq++;
         req.TTL = 1;
         req.protocol = ND_REQ_TYPE;
         memcpy(req.payload, "ND_REQ", 6);
         call SS.send(req, 0xFFFF);
         if ((req.seq % 10) == 0) {
            dbg(GENERAL_CHANNEL, "ND: Sent REQ seq=%d\n", req.seq);
         }
      } else {
         for (i = 0; i < numNeighbors; i++) {
            if (neighbors[i].active) {
               pack req2;
               req2.src = TOS_NODE_ID;
               req2.dest = neighbors[i].addr;
               req2.seq = reqSeq++;
               req2.TTL = 1;
               req2.protocol = ND_REQ_TYPE;
               memcpy(req2.payload, "ND_REQ", 6);
               call SS.send(req2, neighbors[i].addr);
               neighbors[i].numReqSentTo++;
               if ((req2.seq % 10) == 0) {
                  dbg(GENERAL_CHANNEL, "ND: Sent REQ to %d seq=%d\n", neighbors[i].addr, req2.seq);
               }
            }
         }
      }
   }

   void sendNDRep(uint16_t dest) {
      pack rep;
      rep.src = TOS_NODE_ID;
      rep.dest = dest;
      rep.seq = reqSeq++;
      rep.TTL = 1;
      rep.protocol = ND_REP_TYPE;
      memcpy(rep.payload, "ND_REP", 6);
      call SS.send(rep, dest);
      dbg(GENERAL_CHANNEL, "ND: Sent REP to %d\n", dest);
   }

   void ageNeighbors() {
      uint8_t i;
      for (i = 0; i < numNeighbors; i++) {
         if (!neighbors[i].active) continue;
         if (neighbors[i].recentlySeen) {
            neighbors[i].recentlySeen = FALSE; // consume the activity mark
            neighbors[i].missedCount = 0;
         } else {
            if (neighbors[i].missedCount < 255) neighbors[i].missedCount++;
            if (neighbors[i].missedCount > ND_MISS_THRESHOLD) {
               neighbors[i].active = FALSE;
               dbg(GENERAL_CHANNEL, "ND: Aged out neighbor %d\n", neighbors[i].addr);
            }
         }
      }
   }

   void printNeighborTable() {
      uint8_t i;
      dbg(GENERAL_CHANNEL, "ND: Neighbor table (%d entries):\n", numNeighbors);
      for (i = 0; i < numNeighbors; i++) {
         uint16_t sent = neighbors[i].numReqSentTo;
         uint16_t recv = neighbors[i].numRepReceivedFrom;
         uint8_t pct = (sent == 0) ? 0 : (uint8_t)((recv * 100) / sent);
         dbg(GENERAL_CHANNEL, "  %d: addr=%d active=%d link=%d%%\n", 
              i, neighbors[i].addr, neighbors[i].active, pct);
      }
   }

   command void NeighborDiscovery.start() {
      running = TRUE;
      numNeighbors = 0;
      reqSeq = 0;
      call neighborTimer.startPeriodic(ND_REQ_INTERVAL);
      call ageTimer.startPeriodic(ND_REQ_INTERVAL); // age at the same cadence as beacons
      dbg(GENERAL_CHANNEL, "ND: Started\n");
   }

   command void NeighborDiscovery.stop() {
      running = FALSE;
      call neighborTimer.stop();
      call ageTimer.stop();
      dbg(GENERAL_CHANNEL, "ND: Stopped\n");
   }

   command void NeighborDiscovery.findNeighbors() {
      if (running) {
         sendNDReq();
      }
   }

   command void NeighborDiscovery.printNeighbors() {
      printNeighborTable();
   }

   event void neighborTimer.fired() {
      if (running) {
         sendNDReq();
      }
   }

   event void ageTimer.fired() {
      if (running) {
         ageNeighbors();
      }
   }

   // Called by Node with inbound ND packets and the immediate sender
   command void NeighborDiscovery.onReceive(pack* pkt, uint16_t from) {
      neighbor_t* n;
      if (pkt->protocol == ND_REQ_TYPE && pkt->src != TOS_NODE_ID) {
         updateNeighborOnSeen(from);
         sendNDRep(from);
         dbg(GENERAL_CHANNEL, "ND: Received REQ from %d\n", from);
      } else if (pkt->protocol == ND_REP_TYPE && pkt->src != TOS_NODE_ID) {
         updateNeighborOnSeen(from);
         n = findNeighbor(from);
         if (n != NULL) {
            n->numRepReceivedFrom++;
         }
         dbg(GENERAL_CHANNEL, "ND: Received REP from %d\n", from);
      }
   }

   // Accessors
   command uint8_t NeighborDiscovery.getNeighborCount() {
      return numNeighbors;
   }

   command bool NeighborDiscovery.getNeighbor(uint8_t idx, uint16_t* addr, bool* active) {
      if (idx >= numNeighbors) return FALSE;
      if (addr) *addr = neighbors[idx].addr;
      if (active) *active = neighbors[idx].active;
      return TRUE;
   }
}