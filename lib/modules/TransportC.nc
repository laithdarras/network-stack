#include "../../includes/packet.h"

configuration TransportC {
   provides interface Transport;
   uses interface LinkState;
}

implementation {
   components TransportP;
   components new SimpleSendC(AM_PACK) as TransportSend;
   // Transport = TransportP.Transport;
   Transport = TransportP.Transport;
   TransportP.LinkState = LinkState;
   TransportP.SimpleSend -> TransportSend;
}

