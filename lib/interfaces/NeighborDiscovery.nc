#include "../../includes/packet.h"

interface NeighborDiscovery{
   command void findNeighbors();       // Start the neighbor discovery process
   command void printNeighbors();      // Print the neighbor table to the console
   command void start();           // Start the neighbor discovery protocol
   command void stop();      // Stop the neighbor discovery protocol

   command uint8_t getNeighborCount();    // Get the number of neighbors currently in the table
   command bool getNeighbor(uint8_t idx, uint16_t* addr, bool* active);          // Get the neighbor at the given index and its address and active status

   command void onReceive(pack* pkt, uint16_t from);      // Notify ND of a received packet from the node
}
