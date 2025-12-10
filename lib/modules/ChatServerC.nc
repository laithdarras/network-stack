// Configuration for Chat Server

configuration ChatServerC {
   provides interface ChatServer;
   uses interface Transport;
}

implementation {
   components ChatServerP;
   components new TimerMilliC() as AcceptTimerC;
   components new TimerMilliC() as ReadTimerC;
   
   ChatServer = ChatServerP;
   ChatServerP.Transport = Transport;
    ChatServerP.AcceptTimer -> AcceptTimerC;
    ChatServerP.ReadTimer -> ReadTimerC;
}