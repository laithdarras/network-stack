#include "../../includes/am_types.h"

generic configuration NeighborDiscoveryC(int channel){
   provides interface NeighborDiscovery;
}

implementation{
   components new NeighborDiscoveryP();
   NeighborDiscovery = NeighborDiscoveryP.NeighborDiscovery;

   components new TimerMilliC() as neighborTimer;  
   components new TimerMilliC() as ageTimer;
   NeighborDiscoveryP.neighborTimer -> neighborTimer;
   NeighborDiscoveryP.ageTimer -> ageTimer;

   components RandomC as Random;
   NeighborDiscoveryP.Random -> Random;

   components new SimpleSendC(channel) as NDSend;
   NeighborDiscoveryP.SS -> NDSend;         

}
