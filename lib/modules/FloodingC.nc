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
   FloodingP.SS -> FloodSend;

   components new TimerMilliC() as dupTimer;
   FloodingP.dupTimer -> dupTimer;

   FloodingP.ND = NeighborDiscovery;

   // Note: ND interface will be wired in NodeC.nc
}
