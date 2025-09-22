#include <Timer.h>

// Flooding module stub
// Provides Flooding interface and depends on SimpleSend for future logic
module FloodingP{
   provides interface Flooding;
   uses interface SimpleSend as SS;
}

implementation{
   // Placeholder start; real flooding logic to be implemented later
   command void Flooding.start(){
   }
}
