#include <Timer.h>
#include "../../includes/packet.h"
#include "../../includes/channels.h"

// Duplicate tracking entry
typedef struct {
   uint16_t src;
   uint16_t maxSeq;
   uint32_t lastSeen;
} dupEntry_t;

enum {
   MAX_DUP_ENTRIES = 20,
   FLOOD_PROTOCOL = 3,
   DUP_AGE_TIMEOUT = 10000  // 10 seconds
};

module FloodingP{
   provides interface Flooding;

   uses interface SimpleSend as SS;
   uses interface Timer<TMilli> as dupTimer;
   uses interface NeighborDiscovery as ND;
}

implementation {
   dupEntry_t dupTable[MAX_DUP_ENTRIES];
   uint8_t numDupEntries = 0;
   bool running = FALSE;
   bool busy = FALSE;

   dupEntry_t* findDupEntry(uint16_t src) {
      uint8_t i;
      for (i = 0; i < numDupEntries; i++) {
         if (dupTable[i].src == src) {
            return &dupTable[i];
         }
      }
      return NULL;
   }

   void updateDupEntry(uint16_t src, uint16_t seq) {
      dupEntry_t* entry = findDupEntry(src);
      if (entry == NULL && numDupEntries < MAX_DUP_ENTRIES) {
         dupTable[numDupEntries].src = src;
         dupTable[numDupEntries].maxSeq = seq;
         dupTable[numDupEntries].lastSeen = sim_time();
         numDupEntries++;
      } else if (entry != NULL) {
         if (seq > entry->maxSeq) {
            entry->maxSeq = seq;
         }
         entry->lastSeen = sim_time();
      }
   }

   bool isDuplicate(uint16_t src, uint16_t seq) {
      dupEntry_t* entry = findDupEntry(src);
      if (entry == NULL) {
         return FALSE;
      }
      return (seq <= entry->maxSeq);
   }

   void ageDupEntries() {
      uint8_t i;
      uint32_t now = sim_time();
      for (i = 0; i < numDupEntries; i++) {
         if ((now - dupTable[i].lastSeen) > DUP_AGE_TIMEOUT) {
            uint8_t j;
            for (j = i; j < numDupEntries - 1; j++) {
               dupTable[j] = dupTable[j + 1];
            }
            numDupEntries--;
            i--;
         }
      }
   }

   void forwardPerLink(pack* pkt, uint16_t inbound) {
      uint8_t i, count;
      uint16_t neighborAddr;
      bool isActive;

      if (pkt->TTL == 0) {
         dbg(FLOODING_CHANNEL, "Flood: TTL expired, dropping\n");
         return;
      }

      pkt->TTL--;
      count = call ND.getNeighborCount();
      for (i = 0; i < count; i++) {
         if (call ND.getNeighbor(i, &neighborAddr, &isActive) && isActive) {
            if (neighborAddr == inbound) continue; // skip inbound link
            if (busy) continue; // very simple throttle
            busy = TRUE;
            call SS.send(*pkt, neighborAddr);
            busy = FALSE; // SimpleSend is synchronous
            dbg(FLOODING_CHANNEL, "Flood: FWD seq=%d to %d TTL=%d\n", pkt->seq, neighborAddr, pkt->TTL);
         }
      }
   }

   command void Flooding.start() {
      running = TRUE;
      numDupEntries = 0;
      busy = FALSE;
      call dupTimer.startPeriodic(5000);
      dbg(FLOODING_CHANNEL, "Flood: Started\n");
   }

   command void Flooding.stop() {
      running = FALSE;
      call dupTimer.stop();
      dbg(FLOODING_CHANNEL, "Flood: Stopped\n");
   }

   command error_t Flooding.send(pack msg, uint16_t dest) {
      if (!running) return FAIL;
      msg.protocol = FLOOD_PROTOCOL;
      if (msg.TTL == 0) msg.TTL = MAX_TTL;
      updateDupEntry(msg.src, msg.seq);
      dbg(FLOODING_CHANNEL, "Flood: Originating seq=%d TTL=%d\n", msg.seq, msg.TTL);
      forwardPerLink(&msg, 0xFFFF);
      return SUCCESS;
   }

   event void dupTimer.fired() {
      if (running) {
         ageDupEntries();
      }
   }

   // Called by Node with inbound flood packets and the immediate sender
   command void Flooding.onReceive(pack* pkt, uint16_t from) {
      if (!running) return;
      if (pkt->protocol != FLOOD_PROTOCOL) return;
      if (isDuplicate(pkt->src, pkt->seq)) {
         dbg(FLOODING_CHANNEL, "Flood: Duplicate from %d seq=%d\n", pkt->src, pkt->seq);
         return;
      }
      updateDupEntry(pkt->src, pkt->seq);
      signal Flooding.receive(*pkt, from);
      forwardPerLink(pkt, from);
   }
}
