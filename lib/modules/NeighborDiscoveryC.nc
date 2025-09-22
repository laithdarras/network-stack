#include "../../includes/am_types.h"

generic configuration NeighborDiscoveryC(int channel){
   provides interface NeighborDiscovery;
}

// this C file is the configuration file that connects the module to the P file

implementation{
   components new NeighborDiscoveryP();
   NeighborDiscovery = NeighborDiscoveryP.NeighborDiscovery; // wiring the interface

   components new TimerMilliC() as neighborTimer;  
   NeighborDiscoveryP.neighborTimer -> neighborTimer; // wiring the timer

   components RandomC as Random;
    NeighborDiscoveryP.Random -> Random; // wiring the random number generator
}
