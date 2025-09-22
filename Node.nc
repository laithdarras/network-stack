/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * Wiring-only scaffolding: Boot + AMControl + Timer + CommandHandler + ND + Flooding
 * Proves wiring via boot and timer prints; no protocol logic yet.
 */
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"

module Node{
   uses interface Boot;                    

   uses interface SplitControl as AMControl;
   uses interface Receive;                  

   uses interface SimpleSend as SS;        

   uses interface CommandHandler as Cmd;    

   uses interface NeighborDiscovery as ND; 

   uses interface Timer<TMilli> as NDTimer;  

   uses interface Flooding as Flood;       
}

implementation{
   pack sendPackage;

   // Prototypes
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

   // On boot: start radio, print, and start a short one-shot timer
   event void Boot.booted(){
      call AMControl.start();

      dbg(GENERAL_CHANNEL, "Node %d booted; wiring OK\n", TOS_NODE_ID);
      call NDTimer.startOneShot(250);
   }

   event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
         dbg(GENERAL_CHANNEL, "Radio On\n");
      }else{
         // Retry until successful
         call AMControl.start();
      }
   }

   event void AMControl.stopDone(error_t err){}

   // Debug-only receive print (no protocol parsing yet)
   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
      dbg(GENERAL_CHANNEL, "Packet Received\n");
      if(len==sizeof(pack)){
         pack* myMsg=(pack*) payload;
         dbg(GENERAL_CHANNEL, "Package Payload: %s\n", myMsg->payload);
         return msg;
      }
      dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
      return msg;
   }

   // Timer proves wiring only
   event void NDTimer.fired(){
      dbg(GENERAL_CHANNEL, "Node %d NDTimer fired\n", TOS_NODE_ID);
   }

   // Command proves CommandHandler path only (no send/flood yet)
   event void Cmd.ping(uint16_t destination, uint8_t *payload){
      dbg(COMMAND_CHANNEL, "Cmd.ping received in Node: dest %d\n", destination);    // Check wiring only
   }

   event void Cmd.printNeighbors(){}

   event void Cmd.printRouteTable(){}

   event void Cmd.printLinkState(){}

   event void Cmd.printDistanceVector(){}

   event void Cmd.setTestServer(){}

   event void Cmd.setTestClient(){}

   event void Cmd.setAppServer(){}

   event void Cmd.setAppClient(){}

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }
}
