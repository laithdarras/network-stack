// Configuration for Chat Client

configuration ChatClientC {
   provides interface ChatClient;
   uses interface Transport;
}

implementation {
   components ChatClientP;
   components new TimerMilliC() as ReadTimerC;
   
   ChatClient = ChatClientP;
   ChatClientP.Transport = Transport;
   ChatClientP.ReadTimer -> ReadTimerC;
}