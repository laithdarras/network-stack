#include <Timer.h>
#include "../../includes/packet.h"
#include "../../includes/channels.h"

// Neighbor table entry
typedef struct {
   uint16_t addr;     // neighbor address
   bool active;        // neighbor binary activity state
   uint32_t lastSeen;    // last seen time
   uint16_t numReqSentTo;       // # of ND REQ sent to
   uint16_t numRepReceivedFrom;         // # of ND REP received from
   uint8_t missedCount;       // # of missed ND REQ periods
   bool recentlySeen;      // Seem in the last period
} neighbor_t;

enum {
   MAX_NEIGHBORS = 10,          // 10 for small networks
   ND_REQ_INTERVAL = 2000,  // 2 seconds
   ND_MISS_THRESHOLD = 5,   // age out after 5 missed periods
   ND_REQ_TYPE = 1,          // 1 is for ND request packets
   ND_REP_TYPE = 2            // 2 is for ND reply packets
};

generic module NeighborDiscoveryP() {
   provides interface NeighborDiscovery;

   uses interface Timer<TMilli> as neighborTimer;
   uses interface Timer<TMilli> as ageTimer;
   uses interface SimpleSend as SS;
   uses interface Random;
}

implementation {
   // Using an array for the neighbor table
   neighbor_t neighbors[MAX_NEIGHBORS];
   uint8_t numNeighbors = 0;
   bool running = FALSE;
   uint16_t reqSeq = 0;

   // Function to find a neighbor by source address using linear search
   neighbor_t* findNeighbor(uint16_t addr) {
      uint8_t i;
      for (i = 0; i < numNeighbors; i++) {
         if (neighbors[i].addr == addr) {
            return &neighbors[i];
         }
      }
      return NULL;
   }

   // Update or add a neighbor entry when seen in a packet
   void updateNeighborOnSeen(uint16_t addr) {
      neighbor_t* n = findNeighbor(addr);

      // If not found, add new neighbor if not full
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
         // Update existing neighbor
         n->active = TRUE;
         n->recentlySeen = TRUE;
         n->missedCount = 0; // reset on any activity
      }
   }

   // Send ND REQ packets to discover neighbors from either all nodes or known neighbor nodes
   void sendNDReq() {
      uint8_t i;
      if (numNeighbors == 0) {
         // No known neighbors, broadcast to all
         pack req;
         req.src = TOS_NODE_ID;      // assign own address
         req.dest = 0xFFFF;  // initial discovery is broadcast except to self
         req.seq = reqSeq++;         // increment seq # for each REQ
         req.TTL = 1;           // Direct request
         req.protocol = ND_REQ_TYPE;           // set protocol type to ND
         memcpy(req.payload, "ND_REQ", 6);
         call SS.send(req, 0xFFFF);
         if ((req.seq % 10) == 0) {
            // Display every 10th REQ for debugging to reduce console spam
            dbg(GENERAL_CHANNEL, "ND: Sent REQ seq=%d\n", req.seq);
         }
      } else {
         // Send REQ to all known neighbors
         for (i = 0; i < numNeighbors; i++) {
            if (neighbors[i].active) {
               // This is to check if neighbor is active before sending REQs
               pack req2;
               req2.src = TOS_NODE_ID;
               req2.dest = neighbors[i].addr;     // unicast to known neighbor
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

   // Send ND REP packets in response to REQ packets
   void sendNDRep(uint16_t dest) {
      pack rep;
      rep.src = TOS_NODE_ID;
      rep.dest = dest;           // unicast back to requester
      rep.seq = reqSeq++;
      rep.TTL = 1;         // Direct reply
      rep.protocol = ND_REP_TYPE;
      memcpy(rep.payload, "ND_REP", 6);
      call SS.send(rep, dest);
      dbg(GENERAL_CHANNEL, "ND: Sent REP to %d\n", dest);
   }


   // Avoid neighbors that have not been seen recently by aging them out to prevent congestion
   void ageNeighbors() {
      uint8_t i;

      // Iterate through table and age out inactive neighbors
      for (i = 0; i < numNeighbors; i++) {
         if (!neighbors[i].active) continue;        // Skip if already inactive

         // Need to reset counters if recently seen to avoid false positives leading to packet loss
         if (neighbors[i].recentlySeen) {
            neighbors[i].recentlySeen = FALSE;     
            neighbors[i].missedCount = 0;
         } else {

            // Increment missed count of periods not seen and deactivate if over threshold
            if (neighbors[i].missedCount < 255) neighbors[i].missedCount++;     // 255 is max for uint8_t
            if (neighbors[i].missedCount > ND_MISS_THRESHOLD) {          // Deactivate after threshold (5 periods)
               neighbors[i].active = FALSE;
               dbg(GENERAL_CHANNEL, "ND: Aged out neighbor %d\n", neighbors[i].addr);
            }
         }
      }
   }

   // Print the neighbor table to the console
   void printNeighborTable() {
      uint8_t i;
      dbg(GENERAL_CHANNEL, "ND: Neighbor table (%d entries):\n", numNeighbors);

      // Iterate through table and print each neighbor's details
      for (i = 0; i < numNeighbors; i++) {
         uint16_t sent = neighbors[i].numReqSentTo;      // # of REQs sent to this neighbor
         uint16_t recv = neighbors[i].numRepReceivedFrom;    // # of REPs received from this neighbor
         uint8_t pct = (sent == 0) ? 0 : (uint8_t)((recv * 100) / sent);         // measure link quality
         dbg(GENERAL_CHANNEL, "  %d: addr=%d active=%d link=%d%%\n", 
              i, neighbors[i].addr, neighbors[i].active, pct);
      }
   }


   // Start ND
   command void NeighborDiscovery.start() {
      running = TRUE;
      numNeighbors = 0;
      reqSeq = 0;
      call neighborTimer.startPeriodic(ND_REQ_INTERVAL);
      call ageTimer.startPeriodic(ND_REQ_INTERVAL); // age at the same cadence as beacons
      dbg(GENERAL_CHANNEL, "ND: Started\n");
   }


   // Stop ND
   command void NeighborDiscovery.stop() {
      running = FALSE;
      call neighborTimer.stop();
      call ageTimer.stop();
      dbg(GENERAL_CHANNEL, "ND: Stopped\n");
   }


   // Start sending ND REQ packets to discover neighbors
   command void NeighborDiscovery.findNeighbors() {
      if (running) {
         sendNDReq();
      }
   }


   // Print neighbor table to console
   command void NeighborDiscovery.printNeighbors() {
      printNeighborTable();
   }


   // We need to periodically send ND REQ packets to actively discover neighbors
   event void neighborTimer.fired() {
      if (running) {
         sendNDReq();
      }
   }


   // We need to periodically age out old neighbors that have not been seen recently to avoid congestion
   event void ageTimer.fired() {
      if (running) {
         ageNeighbors();
      }
   }

   
   // Handle receive packets from other nodes
   command void NeighborDiscovery.onReceive(pack* pkt, uint16_t from) {
      neighbor_t* n;   // Temp neighbor ptr

      // Handle ND packets by checking type and updating neighbor table
      if (pkt->protocol == ND_REQ_TYPE && pkt->src != TOS_NODE_ID) {
         updateNeighborOnSeen(from);
         sendNDRep(from);
         dbg(GENERAL_CHANNEL, "ND: Received REQ from %d\n", from);

         // Update stats for the neighbor that send the REQ
      } else if (pkt->protocol == ND_REP_TYPE && pkt->src != TOS_NODE_ID) {
         updateNeighborOnSeen(from);
         n = findNeighbor(from);
         // Update stats for existing neighbor that sent the REP
         if (n != NULL) {
            n->numRepReceivedFrom++;
         }
         dbg(GENERAL_CHANNEL, "ND: Received REP from %d\n", from);
      }
   }

   // Method to get # of neighbors in table
   command uint8_t NeighborDiscovery.getNeighborCount() {
      return numNeighbors;
   }

   // Method to get neighbor at index with its info
   command bool NeighborDiscovery.getNeighbor(uint8_t idx, uint16_t* addr, bool* active) {
      if (idx >= numNeighbors) {
         return FALSE;
      }
      if (addr) *addr = neighbors[idx].addr;
      if (active) *active = neighbors[idx].active;
      return TRUE;
   }
}