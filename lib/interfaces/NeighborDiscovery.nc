#include "../../includes/packet.h"

interface NeighborDiscovery{
   command void findNeighbors();       // Start the neighbor discovery process
   command void printNeighbors();      // Print the neighbor table to the console
   command void start();           // Start the neighbor discovery protocol
   command void stop();      // Stop the neighbor discovery protocol

   // Accessors for wired flooding
   command uint8_t getNeighborCount();
   command bool getNeighbor(uint8_t idx, uint16_t* addr, bool* active);

   // Hook to process inbound ND packets (called by Node)
   command void onReceive(pack* pkt, uint16_t from);
}
