// ChatClient interface

interface ChatClient {
   command void startHello(char *username, uint16_t clientPort);        // send a greeting to a user on a port
   command void sendMsg(char *msg);          // broadcast a message to all users on the same connection
   command void sendWhisper(char *username, char *msg);     // send a message to a specific user
   command void sendListUsr();      // print all users on a single connection
}