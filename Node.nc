/*
 * ANDES Lab - University of California, Merced
 *
 */
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/protocol.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"

module Node{
   uses interface Boot;             // Boot interface      

   uses interface SplitControl as AMControl;  // Radio control
   uses interface Receive;                // Receive packets
   uses interface AMPacket;               // Link-layer source address

   uses interface SimpleSend as SS;        // SimpleSend interface

   uses interface CommandHandler as Cmd;    // TinyOS Simulator Command Interface Service

   uses interface NeighborDiscovery as ND; // Neighbor Discover - Project 1

   uses interface Timer<TMilli> as NDTimer;  // Timer for ND module

   uses interface Flooding as Flood;       // Flooding - Project 1
   uses interface LinkState as LS;         // Link-State Routing - Project 2
   uses interface Transport;               // TCP - Project 3
}

implementation {
   pack sendPackage;          
   uint16_t floodSeq = 0;

   // Helper functions to create packets
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

   // On boot: start radio, ND, and Flooding
   event void Boot.booted(){
      call AMControl.start();

      // dbg(GENERAL_CHANNEL, "Node %d booted; starting protocols\n", TOS_NODE_ID);  // Show node boot message
   }

   event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
         // dbg(GENERAL_CHANNEL, "Radio On - starting ND and Flooding\n");   // Show radio message
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
      // dbg(GENERAL_CHANNEL, "RX len=%d proto=%d from=%d\n", len, myMsg->protocol, inbound);

      if(myMsg->protocol == 1 || myMsg->protocol == 2) {    // ND REQ/ND REP
         call ND.onReceive(myMsg, inbound);
      } else if(myMsg->protocol == 3) {               // FLOOD
         call Flood.onReceive(myMsg, inbound);
      } else if(myMsg->protocol == PROTOCOL_TCP) {   // TCP (check before Link-State since both use protocol 4)
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
                  // dbg(GENERAL_CHANNEL, "Routed packet dest=%d via nextHop=%d\n", myMsg->dest, nh);
               } else {
                  // dbg(GENERAL_CHANNEL, "Route failed for dest=%d\n", myMsg->dest);
               }
            } else {
               // dbg(GENERAL_CHANNEL, "No route to dest=%d, dropping\n", myMsg->dest);
            }
         }
      }
      return msg;
   }

   // Timer for periodic operations
   event void NDTimer.fired(){
      // dbg(GENERAL_CHANNEL, "Node %d periodic timer\n", TOS_NODE_ID);
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
   // this needs to be more efficient approach using ip instead of flooding every time which is costly.
      // Fallback: flood
      if(call Flood.send(sendPackage, destination) == SUCCESS) {
         dbg(GENERAL_CHANNEL, "Ping sent via flooding seq=%d\n", sendPackage.seq);
      } else {
         dbg(GENERAL_CHANNEL, "Ping send failed\n");
      }
   }

   // Handle flood receive events
   event void Flood.receive(pack msg, uint16_t from) {
      // dbg(GENERAL_CHANNEL, "Flood received: src=%d seq=%d from=%d TTL=%d\n", 
      //      msg.src, msg.seq, from, msg.TTL);
      if(msg.dest == TOS_NODE_ID) {
         dbg(GENERAL_CHANNEL, "Ping received from %d\n", msg.src);
      }
   }

   event void Cmd.printNeighbors(){
      call ND.printNeighbors();
   }

   // Project 3
   event void Cmd.setTestServer(){
      // TODO: Call Transport.testServer()
   }

   event void Cmd.setTestClient(){
      // TODO: Call Transport.testClient()
   }

   event void Cmd.setTestClose(){
      // TODO: Call Transport.testClose() after close()
   }

   // Project 2
   event void Cmd.printRouteTable(){
      // dbg(COMMAND_CHANNEL, "Cmd: printRouteTable\n");
      // Print LSAs first, then routing table
      call LS.printLinkStateDB();
      call LS.printRouteTable();
   }
   event void Cmd.printLinkState(){
      call LS.printLinkStateDB();
   event void Cmd.printDistanceVector(){}

   // Project 3
   event void Cmd.setTestServer(){}
   event void Cmd.setTestClient(){}
   event void Cmd.setTestClose(){}

   // Project 4
   event void Cmd.setAppServer(){}
   event void Cmd.setAppClient(){}

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
