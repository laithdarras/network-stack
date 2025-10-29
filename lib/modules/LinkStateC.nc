#include "../../includes/packet.h"
configuration LinkStateC {
   provides interface LinkState;
   uses interface NeighborDiscovery;
}
implementation {
   components LinkStateP, FloodingC;
   components new TimerMilliC() as LsaTimerC;
   
   LinkState = LinkStateP.LinkState;
   LinkStateP.Flooding -> FloodingC.Flooding;
   LinkStateP.NeighborDiscovery = NeighborDiscovery;
   LinkStateP.lsaTimer -> LsaTimerC;
}
