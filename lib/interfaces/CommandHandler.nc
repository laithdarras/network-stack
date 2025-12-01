interface CommandHandler{
   // Events
   event void ping(uint16_t destination, uint8_t *payload);
   event void printNeighbors();
   event void printRouteTable();
   event void printLinkState();
   event void printDistanceVector();
   event void setTestServer();
   event void setTestClient();
   event void setTestClose();
   event void setAppServer();
   event void setAppClient();

   // p3 accessories
   command uint16_t getTestServerAddress();
   command uint16_t getTestServerPort();

   command uint16_t getTestClientAddress();
   command uint16_t getTestClientDest();
   command uint16_t getTestClientSrcPort();
   command uint16_t getTestClientDestPort();
   command uint16_t getTestClientTransfer();

   command uint16_t getTestCloseClientAddr();
   command uint16_t getTestCloseDest();
   command uint16_t getTestCloseSrcPort();
   command uint16_t getTestCloseDestPort();
}
