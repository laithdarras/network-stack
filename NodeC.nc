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

    Node -> MainC.Boot;

    Node.Receive -> GeneralReceive;

    components ActiveMessageC;
    Node.AMControl -> ActiveMessageC;
    Node.AMPacket -> ActiveMessageC;

    components new SimpleSendC(AM_PACK);
    Node.SS -> SimpleSendC;

    components CommandHandlerC;
    Node.Cmd -> CommandHandlerC;

    components new TimerMilliC();
    Node.NDTimer -> TimerMilliC;

    // Neighbor Discovery module (shared instance)
    components new NeighborDiscoveryC(6) as NeighborDiscoveryC;
    Node.ND -> NeighborDiscoveryC.NeighborDiscovery;

    // Flooding module
    components FloodingC;
    Node.Flood -> FloodingC.Flooding;
    FloodingC.NeighborDiscovery -> NeighborDiscoveryC.NeighborDiscovery;

    // Link-State Routing module
    components LinkStateC;
    Node.LS -> LinkStateC.LinkState;
    LinkStateC.NeighborDiscovery -> NeighborDiscoveryC.NeighborDiscovery;

    // Transport/TCP module (Project 3 - commented until implemented)
    // components TransportC;
    // TransportC.LinkState -> LinkStateC.LinkState;
}
