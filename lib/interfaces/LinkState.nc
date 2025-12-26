#include "../../includes/packet.h"

interface LinkState{
   command void start();      // start the shortest path computation
   command void stop();       // stop the shortest path computation
   command void recomputeRoutes();     // restart shortest path computation due to change in topology
   command uint16_t nextHop(uint16_t dest);     // find next hop of route
   command void printRouteTable();        // list the route paths (next hop + distance to each destination)
   command void printLinkStateDB();    // print topology data from each node
}