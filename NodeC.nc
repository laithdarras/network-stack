#include <Timer.h>
#include "includes/CommandMsg.h"
#include "includes/packet.h"

configuration NodeC{
}
implementation {
    components MainC;
    components Node;
    components new AMReceiverC(AM_PACK) as GeneralReceive;

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

    components new TimerMilliC() as ServerTimerC;
    components new TimerMilliC() as ClientTimerC;
    Node.ServerTimer -> ServerTimerC;
    Node.ClientTimer -> ClientTimerC;

    // Neighbor Discovery module
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

    // Transport module
    components TransportC;
    TransportC.LinkState -> LinkStateC.LinkState;
    Node.Transport -> TransportC;
    
    // Chat/Server module
    components ChatClientC;
    components ChatServerC;
    Node.ChatClient -> ChatClientC;
    ChatClientC.Transport -> TransportC;
    Node.ChatServer -> ChatServerC;
    ChatServerC.Transport -> TransportC;
}