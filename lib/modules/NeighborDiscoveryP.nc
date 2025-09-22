#include <Timer.h>

generic module NeighborDiscoveryP() {
   provides interface NeighborDiscovery;

   uses interface Timer<TMilli> as neighborTimer;  // this is for periodic neighbor discovery
   uses interface Random;  // for random wait times to avoid congestion
}

implementation {

   task void search() {
       // placeholder for neighbor search logic
       // restart the timer for periodic neighbor discovery
       call neighborTimer.startPeriodic(100 + (call Random.rand16() % 300));
   }

   command void NeighborDiscovery.findNeighbors() {
       // 100 ms + random 0-300 ms; oneshot boot strap
       call neighborTimer.startOneShot(100 + (call Random.rand16() % 300));
   }

   event void neighborTimer.fired() {
       post search();
   }

   command void NeighborDiscovery.printNeighbors() {
       // placeholder for printing neighbors later
   }
}