#include "../../includes/packet.h"

interface Flooding{
   command void start();  // start the flooding protocol
   command void stop();   // stop the flooding protocol
   command error_t send(pack msg, uint16_t dest);          // send a packet to a destination
   command void onReceive(pack* pkt, uint16_t from);        // notify flooding of a received packet from neighbor discovery
   event void receive(pack msg, uint16_t from);            // event to notify a node of a received flooding packet
}
