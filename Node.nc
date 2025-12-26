#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/protocol.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"
#include "includes/socket.h"
#include "includes/Transport.h"

module Node{
   uses interface Boot;             // Boot interface      

   uses interface SplitControl as AMControl;  // Radio control
   uses interface Receive;                // Receive packets
   uses interface AMPacket;               // Link-layer source address

   uses interface SimpleSend as SS;        // SimpleSend interface

   uses interface CommandHandler as Cmd;    // TinyOS Simulator Command Interface Service

   uses interface NeighborDiscovery as ND;

   uses interface Timer<TMilli> as NDTimer;  // Timer for ND module
   uses interface Timer<TMilli> as ServerTimer;
   uses interface Timer<TMilli> as ClientTimer;

   uses interface Flooding as Flood;
   uses interface LinkState as LS;
   uses interface Transport;
   
   // Chat application
   uses interface ChatClient;
   uses interface ChatServer;
}

implementation {
   pack sendPackage;          
   uint16_t floodSeq = 0;

   // Transport testing globals
   enum { MAX_SERVER_CONNECTIONS = 8 };
   socket_t serverFd = NULL_SOCKET;
   socket_t serverAccepted[MAX_SERVER_CONNECTIONS];
   uint8_t serverReadBuf[64];
   uint16_t serverPort = 0;

   socket_t clientFd = NULL_SOCKET;
   uint16_t clientDestAddr = 0;
   uint16_t clientSrcPort = 0;
   uint16_t clientDestPort = 0;
   uint16_t clientNextValue = 0;
   uint16_t clientTransferLimit = 0;
   bool clientActive = FALSE;
   uint8_t clientWriteBuf[64];

   void resetServerConnections() {
      uint8_t i;
      for (i = 0; i < MAX_SERVER_CONNECTIONS; i++) {
         serverAccepted[i] = NULL_SOCKET;
      }
   }

   // Helper functions to create packets
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

   // On boot: start radio, ND, and Flooding
   event void Boot.booted(){
      resetServerConnections();
      serverFd = NULL_SOCKET;
      clientFd = NULL_SOCKET;
      call AMControl.start();
      
      // Start chat server on node 1
      if (TOS_NODE_ID == 1) {
         call ChatServer.start();
      }
   }

   event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
         call ND.start();
         call Flood.start();
         call LS.start();
      }else{
         // Retry until successful
         call AMControl.start();
      }
   }

   event void AMControl.stopDone(error_t err){}  // Edge case when radio stops

   // Handler for all received packets
   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
      pack* myMsg = (pack*) payload;
      uint16_t inbound = call AMPacket.source(msg);

      if(myMsg->protocol == 1 || myMsg->protocol == 2) {    // ND REQ/ND REP
         call ND.onReceive(myMsg, inbound);
      } else if(myMsg->protocol == 3) {               // FLOOD
         call Flood.onReceive(myMsg, inbound);
      } else if(myMsg->protocol == PROTOCOL_TCP) {   // TCP
            if(myMsg->dest == TOS_NODE_ID) {
               // Deliver to transport layer
               call Transport.receive(myMsg);
            } else {
               // Route to next hop
               uint16_t next_hop = call LS.nextHop(myMsg->dest);
               if (next_hop != 0xFFFF) {
                  call SS.send(*myMsg, next_hop);
               }
            }
      } else if(myMsg->protocol == 4) {               // Link-State
         call Flood.onReceive(myMsg, inbound);
      } else {
         // Regular data packet - route or deliver
         if(myMsg->dest == TOS_NODE_ID) {
            // Packet is for this node - deliver locally
            dbg(GENERAL_CHANNEL, "Ping received from %d\n", myMsg->src);
         } else if(myMsg->dest == 0xFFFF) {
            // Broadcast - flood it
            call Flood.onReceive(myMsg, inbound);
         } else {
            // Packet is for another node - route it using routing table
            uint16_t nh = call LS.nextHop(myMsg->dest);
            if (nh != 0xFFFF) {
               if (call SS.send(*myMsg, nh) == SUCCESS) {
                  dbg(GENERAL_CHANNEL, "Routed packet dest=%d via nextHop=%d\n", myMsg->dest, nh);
               } else {
                  dbg(GENERAL_CHANNEL, "Route failed for dest=%d\n", myMsg->dest);
               }
            } else {
               dbg(GENERAL_CHANNEL, "No route to dest=%d, dropping\n", myMsg->dest);
            }
         }
      }
      return msg;
   }

   // Timer for periodic operations
   event void NDTimer.fired(){
      call NDTimer.startOneShot(5000);  // 5 second intervals
   }

   // Handle ping command - send via flooding
   event void Cmd.ping(uint16_t destination, uint8_t *payload){
      dbg(COMMAND_CHANNEL, "Cmd.ping received: dest %d\n", destination);
      
      // Create flood packet
      makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, 0, floodSeq++, payload, PACKET_MAX_PAYLOAD_SIZE);
      
      // Try LS routing first
      {
         uint16_t nh = call LS.nextHop(destination);
         if (nh != 0xFFFF) {
            if (call SS.send(sendPackage, nh) == SUCCESS) {
               dbg(GENERAL_CHANNEL, "Ping sent via LS nextHop=%d seq=%d\n", nh, sendPackage.seq);
               return;
            }
         }
      }
   }

   // Handle flood receive events
   event void Flood.receive(pack msg, uint16_t from) {
      if(msg.dest == TOS_NODE_ID) {
         dbg(GENERAL_CHANNEL, "Ping received from %d\n", msg.src);
      }
   }

   event void Cmd.printNeighbors(){
      call ND.printNeighbors();
   }

   event void Cmd.printRouteTable(){
      // Print LSAs first, then routing table
      call LS.printLinkStateDB();
      call LS.printRouteTable();
   }
   
   event void Cmd.printLinkState(){
      call LS.printLinkStateDB();
   }
   
   event void Cmd.printDistanceVector(){}
   
   event void Cmd.setTestServer(){
      socket_addr_t addr;
      error_t err;
      uint16_t targetAddr = call Cmd.getTestServerAddress();
      uint16_t targetPort = call Cmd.getTestServerPort();

      if (targetAddr != 0 && targetAddr != TOS_NODE_ID) {
         dbg("TransportTest", "setTestServer: command for node %hu ignored on %hu\n",
             targetAddr, TOS_NODE_ID);
         return;
      }

      if (serverFd != NULL_SOCKET) {
         dbg("TransportTest", "setTestServer: server already running on node %hu\n", TOS_NODE_ID);
         return;
      }

      if (targetPort == 0) {
         targetPort = 123;
      }
      serverPort = targetPort;

      serverFd = call Transport.socket();
      if (serverFd == NULL_SOCKET) {
         dbg("TransportTest", "setTestServer: socket alloc failed on node %hu\n", TOS_NODE_ID);
         return;
      }

      addr.addr = TOS_NODE_ID;
      addr.port = serverPort;

      err = call Transport.bind(serverFd, &addr);
      if (err != SUCCESS) {
         dbg("TransportTest", "setTestServer: bind failed on node %hu port=%hu\n", TOS_NODE_ID, serverPort);
         call Transport.close(serverFd);
         serverFd = NULL_SOCKET;
         return;
      }

      err = call Transport.listen(serverFd);
      if (err != SUCCESS) {
         dbg("TransportTest", "setTestServer: listen failed on node %hu port=%hu\n", TOS_NODE_ID, serverPort);
         call Transport.close(serverFd);
         serverFd = NULL_SOCKET;
         return;
      }

      resetServerConnections();

      dbg("TransportTest", "Server started node=%hu port=%hu\n", TOS_NODE_ID, serverPort);
      call ServerTimer.startPeriodic(500);
   }

   event void ServerTimer.fired() {
      socket_t newFd;
      uint8_t i;
      bool stored;

      if (serverFd == NULL_SOCKET) {
         call ServerTimer.stop();
         return;
      }

      // Accept all pending connections (accept() returns one per call)
      while (TRUE) {
         newFd = call Transport.accept(serverFd);
         if (newFd == NULL_SOCKET) {
            break;
         }
         
         stored = FALSE;
         for (i = 0; i < MAX_SERVER_CONNECTIONS; i++) {
            if (serverAccepted[i] == NULL_SOCKET) {
               serverAccepted[i] = newFd;
               stored = TRUE;
               dbg("TransportTest", "accept(): node=%hu accepted fd=%hhu\n", TOS_NODE_ID, newFd);
               break;
            }
         }
         if (!stored) {
            dbg("TransportTest", "accept(): connection limit reached on node %hu\n", TOS_NODE_ID);
            call Transport.close(newFd);
            break;
         }
      }

      for (i = 0; i < MAX_SERVER_CONNECTIONS; i++) {
            socket_t fd = serverAccepted[i];
            if (fd == NULL_SOCKET) {
               continue;
            }
            {
               uint16_t n = call Transport.read(fd, serverReadBuf, sizeof(serverReadBuf));
               if (n > 1) {
                  uint16_t idx = 0;
                  dbg("TransportTest", "Reading Data (fd=%hhu):", fd);
                  while (idx + 1 < n) {
                     uint16_t value =
                        ((uint16_t)serverReadBuf[idx] << 8) |
                        ((uint16_t)serverReadBuf[idx + 1]);
                     dbg("TransportTest", "%hu,", value);
                     idx += 2;
                  }
                  dbg("TransportTest", "\n");
               }
            }
      }
   }

   event void Cmd.setTestClient(){
      socket_addr_t addr;
      error_t err;
      uint16_t targetAddr = call Cmd.getTestClientAddress();

      if (targetAddr != 0 && targetAddr != TOS_NODE_ID) {
         dbg("TransportTest", "setTestClient: command for node %hu ignored on %hu\n",
             targetAddr, TOS_NODE_ID);
         return;
      }

      if (clientFd != NULL_SOCKET) {
         dbg("TransportTest", "setTestClient: client already active on node %hu\n", TOS_NODE_ID);
         return;
      }

      clientDestAddr = call Cmd.getTestClientDest();
      clientSrcPort = call Cmd.getTestClientSrcPort();
      clientDestPort = call Cmd.getTestClientDestPort();
      clientTransferLimit = call Cmd.getTestClientTransfer();

      if (clientDestAddr == 0 || clientSrcPort == 0 || clientDestPort == 0) {
         dbg("TransportTest", "setTestClient: missing parameters on node %hu\n", TOS_NODE_ID);
         return;
      }

      clientFd = call Transport.socket();
      if (clientFd == NULL_SOCKET) {
         dbg("TransportTest", "setTestClient: socket alloc failed on node %hu\n", TOS_NODE_ID);
         return;
      }

      addr.addr = TOS_NODE_ID;
      addr.port = clientSrcPort;
      err = call Transport.bind(clientFd, &addr);
      if (err != SUCCESS) {
         dbg("TransportTest", "setTestClient: bind failed node=%hu port=%hu\n", TOS_NODE_ID, clientSrcPort);
         call Transport.close(clientFd);
         clientFd = NULL_SOCKET;
         return;
      }

      addr.addr = clientDestAddr;
      addr.port = clientDestPort;
      err = call Transport.connect(clientFd, &addr);
      if (err != SUCCESS) {
         dbg("TransportTest", "setTestClient: connect failed dest=%hu:%hu\n",
             clientDestAddr, clientDestPort);
         call Transport.close(clientFd);
         clientFd = NULL_SOCKET;
         return;
      }

      clientNextValue = 0;
      clientActive = TRUE;
      dbg("TransportTest", "Client started node=%hu -> %hu:%hu transfer=%hu\n",
          TOS_NODE_ID, clientDestAddr, clientDestPort, clientTransferLimit);
      call ClientTimer.startPeriodic(500);
   }

   event void ClientTimer.fired() {
      uint16_t valuesPrepared = 0;
      uint16_t maxValues = sizeof(clientWriteBuf) / 2;
      uint16_t bufLen = 0;
      uint16_t written;

      if (!clientActive || clientFd == NULL_SOCKET) {
          call ClientTimer.stop();
          return;
      }

      while (valuesPrepared < maxValues && clientNextValue <= clientTransferLimit) {
         uint16_t v = clientNextValue;
         clientWriteBuf[bufLen] = (uint8_t)((v >> 8) & 0xFF);
         clientWriteBuf[bufLen + 1] = (uint8_t)(v & 0xFF);
         bufLen += 2;
         valuesPrepared++;
         clientNextValue++;
      }

      if (bufLen == 0) {
         return;
      }

      written = call Transport.write(clientFd, clientWriteBuf, bufLen);
      if (written == 0) {
         clientNextValue -= valuesPrepared;
         return;
      }

      if (written < bufLen) {
         uint16_t sentValues = written / 2;
         uint16_t unsentValues = valuesPrepared - sentValues;
         if (unsentValues > 0) {
            clientNextValue -= unsentValues;
         }
      }

      dbg("TransportTest", "Client wrote %hu bytes from node %hu\n", written, TOS_NODE_ID);
   }

   event void Cmd.setTestClose(){
      uint16_t closeAddr = call Cmd.getTestCloseClientAddr();
      if (closeAddr != TOS_NODE_ID) {
         return;
      }

      if (clientFd != NULL_SOCKET) {
         uint16_t dest = call Cmd.getTestCloseDest();
         uint16_t srcPort = call Cmd.getTestCloseSrcPort();
         uint16_t destPort = call Cmd.getTestCloseDestPort();
         if (clientDestAddr == dest &&
             clientSrcPort == srcPort &&
             clientDestPort == destPort) {
            dbg("TransportTest", "Client closing connection on node %hu\n", TOS_NODE_ID);
            call Transport.close(clientFd);
            clientFd = NULL_SOCKET;
            clientActive = FALSE;
            call ClientTimer.stop();
         }
      }
   }
   event void Cmd.setAppServer(){}
   event void Cmd.setAppClient(){}

   // Chat command handlers
   
   event void Cmd.chatHello(char *username, uint16_t clientPort) {
      call ChatClient.startHello(username, clientPort);
   }
   
   event void Cmd.chatMsg(char *msg) {
      call ChatClient.sendMsg(msg);
   }
   
   event void Cmd.chatWhisper(char *username, char *msg) {
      call ChatClient.sendWhisper(username, msg);
   }
   
   event void Cmd.chatListUsr() {
      call ChatClient.sendListUsr();
   }

   // Create packets
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }
}
