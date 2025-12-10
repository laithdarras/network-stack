// ChatClient interface

interface ChatClient {
   command void startHello(char *username, uint16_t clientPort);
   command void sendMsg(char *msg);
   command void sendWhisper(char *username, char *msg);
   command void sendListUsr();
}