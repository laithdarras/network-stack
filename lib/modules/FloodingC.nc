#include "../../includes/am_types.h"

// Flooding configuration: exposes Flooding and wires its P module
// Owns a dedicated SimpleSend instance (no logic yet)
configuration FloodingC{
   provides interface Flooding;
}

implementation{
   components FloodingP;
   Flooding = FloodingP.Flooding;

   components new SimpleSendC(AM_PACK) as FloodSend;
   FloodingP.SS -> FloodSend;
}
