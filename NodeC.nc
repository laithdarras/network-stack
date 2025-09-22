/**
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
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

    // Boot
    Node -> MainC.Boot;

    // Raw receive (debug only)
    Node.Receive -> GeneralReceive;

    // Radio control
    components ActiveMessageC;
    Node.AMControl -> ActiveMessageC;

    // App SimpleSend instance
    components new SimpleSendC(AM_PACK);
    Node.SS -> SimpleSendC;

    // TOSSIM Command handler
    components CommandHandlerC;
    Node.Cmd -> CommandHandlerC;

    // Timer used by Node for wiring check
    components new TimerMilliC();
    Node.NDTimer -> TimerMilliC;

    // Neighbor Discovery module
    components new NeighborDiscoveryC(0) as NeighborDiscoveryC;
    Node.ND -> NeighborDiscoveryC;

    // Flooding module
    components FloodingC;
    Node.Flood -> FloodingC;
}
