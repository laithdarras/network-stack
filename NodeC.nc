/**
 * ANDES Lab - University of California, Merced
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */

#include <Timer.h>
#include "includes/CommandMsg.h"
#include "includes/packet.h"

configuration NodeC{
}
implementation {
    components MainC;
    components Node;
    components new AMReceiverC(AM_PACK) as GeneralReceive; // debug receive path

    // Boot the Main Controller Program
    Node -> MainC.Boot;

    // Raw receive (debug only)
    Node.Receive -> GeneralReceive;

    // Radio control for sending and receiving packets
    components ActiveMessageC;
    Node.AMControl -> ActiveMessageC;
    Node.AMPacket -> ActiveMessageC;

    // SimpleSend for sending packets in the network to other nodes in the topology
    components new SimpleSendC(AM_PACK);
    Node.SS -> SimpleSendC;

    // TOSSIM Command handler
    components CommandHandlerC;
    Node.Cmd -> CommandHandlerC;

    // Timer used by Node for wiring check
    components new TimerMilliC();
    Node.NDTimer -> TimerMilliC;

    // Neighbor Discovery module
    components new NeighborDiscoveryC(AM_PACK) as NeighborDiscoveryC;
    Node.ND -> NeighborDiscoveryC;

    // Flooding module
    components FloodingC;
    Node.Flood -> FloodingC;
    FloodingC.NeighborDiscovery -> NeighborDiscoveryC;
}
