#include "../../includes/am_types.h"

// Flooding configuration: exposes Flooding and wires its P module
configuration FloodingC{
   provides interface Flooding;
   uses interface NeighborDiscovery;
}

implementation{
   components FloodingP;
   Flooding = FloodingP.Flooding;

   components new SimpleSendC(AM_PACK) as FloodSend;
   FloodingP.SS -> FloodSend;       // Sending packets to the lower link layer for transmission

   components new TimerMilliC() as dupTimer;
   FloodingP.dupTimer -> dupTimer;   // Checking for duplicates is important in flooding to prevent network congestion

   FloodingP.ND = NeighborDiscovery;  // Flooding needs access to ND's neighbor table for per-link forwarding
}
