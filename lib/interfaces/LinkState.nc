#include "../../includes/packet.h"

interface LinkState{
   command void start();
   command void stop();
   // Dijkstra to be implemented later
   command void recomputeRoutes();
   // Return next hop toward dest or INVALID_NODE if unreachable
   command uint16_t nextHop(uint16_t dest);
   // Print the current routing table
   command void printRouteTable();
}


