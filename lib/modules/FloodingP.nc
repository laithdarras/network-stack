#include <Timer.h>
#include "../../includes/packet.h"
#include "../../includes/channels.h"

// This struct keeps track of the highest sequence number seen from a single source node to detect duplicates
typedef struct {
   uint16_t src;
   uint16_t maxSeq;
   uint32_t lastSeen;
} dupEntry_t;

enum {
   MAX_DUP_ENTRIES = 20,      // 20 because we have at most 20 neighbors
   FLOOD_PROTOCOL = 3,       // 3 because 1=ND, 2=Routing
   DUP_AGE_TIMEOUT = 10000  // 10 seconds because nodes should re-flood within this time
};

module FloodingP{
   provides interface Flooding;

   uses interface SimpleSend as SS;
   uses interface Timer<TMilli> as dupTimer;
   uses interface NeighborDiscovery as ND;
}

implementation {
   dupEntry_t dupTable[MAX_DUP_ENTRIES];       // Create an array to hold duplicate node entries in the table
   uint8_t numDupEntries = 0;
   bool running = FALSE;


   // Function to find a duplicate entry by source addr
   dupEntry_t* findDupEntry(uint16_t src) {
      uint8_t i;
      for (i = 0; i < numDupEntries; i++) {  // run linear search
         if (dupTable[i].src == src) {
            return &dupTable[i];      // duplicate entry found
         }
      }
      return NULL;   // not found
   }


   // Update or add a duplicate entry from a received packet
   void updateDupEntry(uint16_t src, uint16_t seq) {
      dupEntry_t* entry = findDupEntry(src); // Look for existing entry

      // If not found, check for space to add new entry
      if (entry == NULL && numDupEntries < MAX_DUP_ENTRIES) {
         // Add new entry based on src addr and seq #
         dupTable[numDupEntries].src = src;
         dupTable[numDupEntries].maxSeq = seq;
         dupTable[numDupEntries].lastSeen = sim_time();
         numDupEntries++;                                   // Increment count of entries in table

         // If table full, just overwrite oldest entry
      } else if (entry != NULL) {
         if (seq > entry->maxSeq) {
            entry->maxSeq = seq;
         }
         entry->lastSeen = sim_time();    // Update last seen time
      }
   }


   // checks if a packet is a duplicate
   bool isDuplicate(uint16_t src, uint16_t seq) {
      dupEntry_t* entry = findDupEntry(src);      // check existing

      // If none, not a dup
      if (entry == NULL) {
         return FALSE;
      }
      return (seq <= entry->maxSeq);      // Packet is a dup since seq # always increases
   }


   // Remove old entries from table
   void ageDupEntries() {
      uint8_t i;
      uint32_t now = sim_time();

      // Iterate through table and remove old entries by checking if the lastSeen time is older than the age timeout which is 10s
      for (i = 0; i < numDupEntries; i++) {
         if ((now - dupTable[i].lastSeen) > DUP_AGE_TIMEOUT) {
            uint8_t j;
            // Remove entry by shifting later entries down
            for (j = i; j < numDupEntries - 1; j++) {
               dupTable[j] = dupTable[j + 1];   // Shift down the table
            }
            numDupEntries--;   // Decrement for removal of entry
            i--;  // Check index once more since it's now a new entry
         }
      }
   }


   // Forwarding function that sends to all neighbors except itself and the neighbor it received from
   void forwardPerLink(pack* pkt, uint16_t inbound) {
      uint8_t i, count;
      uint16_t neighborAddr;
      bool isActive;

      // Drop if TTL expired
      if (pkt->TTL == 0) {
         dbg(FLOODING_CHANNEL, "Flood: TTL expired, dropping\n");
         return;
      }

      // Constantly decrement TTL for each hop
      pkt->TTL--;
      count = call ND.getNeighborCount();

      // Iterate through neighbor table and send to each active neighbor except the neighbor it received the packet from
      for (i = 0; i < count; i++) {
         if (call ND.getNeighbor(i, &neighborAddr, &isActive) && isActive) {
            if (neighborAddr == inbound) continue; // skip inbound link (don't send back to where it came from)
            call SS.send(*pkt, neighborAddr); // SimpleSend is synchronous so it will block the node until send is done
            dbg(FLOODING_CHANNEL, "Flood: FWD seq=%d to %d TTL=%d\n", pkt->seq, neighborAddr, pkt->TTL);       // Shows flooding activity
         }
      }
   }


   // Start to flood
   command void Flooding.start() {
      running = TRUE;   // Set as active
      numDupEntries = 0;    // Clear dup table
      call dupTimer.startPeriodic(5000);   // Age dup entries every 5s
      dbg(FLOODING_CHANNEL, "Flood: Started\n");
   }


   // Stop flooding
   command void Flooding.stop() {
      running = FALSE;     // Set as inactive
      call dupTimer.stop();     // Stop dup timer
      dbg(FLOODING_CHANNEL, "Flood: Stopped\n");
   }

   // Called by a node to send a flood packet to a destination
   command error_t Flooding.send(pack msg, uint16_t dest) {
      if (!running) return FAIL;
      msg.protocol = FLOOD_PROTOCOL;
      if (msg.TTL == 0) msg.TTL = MAX_TTL;
      updateDupEntry(msg.src, msg.seq);    // Update own entry to prevent re-receiving own flood packets
      if (msg.payload[0]=='L' && msg.payload[1]=='S' && msg.payload[2]=='A') {
         dbg(FLOODING_CHANNEL, "Flooding: Sending LSA from %d seq=%d TTL=%d\n", msg.src, msg.seq, msg.TTL);
      } else {
         dbg(FLOODING_CHANNEL, "Flood: Originating seq=%d TTL=%d\n", msg.seq, msg.TTL);
      }
      forwardPerLink(&msg, 0xFFFF);  // Broadcast to all neighbors, so inbound is invalid
      return SUCCESS;
   }

   // Timer event to age out old dup entries
   event void dupTimer.fired() {
      if (running) {
         ageDupEntries();
      }
   }

   // Handle received packets from ND to check for dups and forward if not a dup
   command void Flooding.onReceive(pack* pkt, uint16_t from) {
      if (!running) return;
      if (pkt->protocol != FLOOD_PROTOCOL) return;
      if (isDuplicate(pkt->src, pkt->seq)) {
         dbg(FLOODING_CHANNEL, "Flood: Duplicate from %d seq=%d\n", pkt->src, pkt->seq);
         return;
      }
      updateDupEntry(pkt->src, pkt->seq);
      if (pkt->payload[0]=='L' && pkt->payload[1]=='S' && pkt->payload[2]=='A') {
         dbg(FLOODING_CHANNEL, "Flooding: Forwarding LSA from %d seq=%d\n", pkt->src, pkt->seq);
      }
      signal Flooding.receive(*pkt, from);
      forwardPerLink(pkt, from);
   }
}
