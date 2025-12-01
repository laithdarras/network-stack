#include "../../includes/packet.h"

configuration TransportC {
   provides interface Transport;
   uses interface LinkState;
}

implementation {
   components TransportP;
   components new SimpleSendC(AM_PACK) as TransportSend;
   components ActiveMessageC;
   components new TimerMilliC() as TestTimerC;
   components new TimerMilliC() as RetransTimerC;
   components MainC;
   
   // Transport = TransportP.Transport;
   Transport = TransportP.Transport;
   TransportP.LinkState = LinkState;
   TransportP.SimpleSend -> TransportSend;
   TransportP.Packet -> ActiveMessageC;
   TransportP.TestTimer -> TestTimerC;
   TransportP.RetransTimer -> RetransTimerC;
   TransportP.Boot -> MainC.Boot;
}

