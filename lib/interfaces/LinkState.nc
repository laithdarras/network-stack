#include "../../includes/packet.h"

interface LinkState{
   command void start();
   command void stop();
   command void recomputeRoutes();
   command uint16_t nextHop(uint16_t dest);
   command void printRouteTable();
   command void printLinkStateDB();
}


