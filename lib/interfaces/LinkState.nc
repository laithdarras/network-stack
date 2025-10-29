#include "../../includes/packet.h"

interface LinkState{
   command void start();
   command void stop();
   // Dijkstra to be implemented later
   command void recomputeRoutes();
}


