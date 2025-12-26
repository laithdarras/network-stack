#include "../../includes/packet.h"
#include "../../includes/sendInfo.h"
#include "../../includes/channels.h"

generic module SimpleSendP(){

   provides interface SimpleSend;

   uses interface Queue<sendInfo*>;
   uses interface Pool<sendInfo>;

   uses interface Timer<TMilli> as sendTimer;

   uses interface Packet;
   uses interface AMPacket;
   uses interface AMSend;

   uses interface Random;
}

implementation{
   uint16_t sequenceNum = 0;
   bool busy = FALSE;
   message_t pkt;

   error_t send(uint16_t src, uint16_t dest, pack *message);

   // Call this method to send a task to add a delay between sends (to avoid collisions)
   void postSendTask(){
      if(call sendTimer.isRunning() == FALSE){
         call sendTimer.startOneShot( (call Random.rand16() %300));
      }
   }

   // This is a wrapper around the am sender, that adds queuing and delayed sending
      command error_t SimpleSend.send(pack msg, uint16_t dest) {

      // Check for room in the queue
      if(!call Pool.empty()){
         sendInfo *input;

         input = call Pool.get();
         input->packet = msg;
         input->dest = dest;

         // Now that we have a value from the pool we can put it into our queue
         call Queue.enqueue(input);

         // Start a send task which will be delayed.
         postSendTask();

         return SUCCESS;
      }
      return FAIL;
   }

   task void sendBufferTask(){
       // If there are values in the queue and the radio is not busy, then attempt to send a packet
      if(!call Queue.empty() && !busy){
         sendInfo *info;
         // Only peek since there is a possibility that the value will NOT be sent so we can resend
         info = call Queue.head();

         // Attempt to send
         if(SUCCESS == send(info->src,info->dest, &(info->packet))){
            call Queue.dequeue();
            call Pool.put(info);
         }


      }

      // While the queue is not empty, run the task
      if(!call Queue.empty()){
         postSendTask();
      }
   }

   // Once the timer fires, we post the sendBufferTask(). This will allow the OS's scheduler to attempt to send a packet at the next empty slot
   event void sendTimer.fired(){
      post sendBufferTask();
   }

   // Send a packet
   error_t send(uint16_t src, uint16_t dest, pack *message){
      if(!busy){
          // Put the data into the payload of the pkt struct
          // getPayload acquires the payload pointer from &pkt and we type cast it to our own packet type
         pack* msg = (pack *)(call Packet.getPayload(&pkt, sizeof(pack) ));

         // Copy the data to new packet type
         *msg = *message;

         // Attempt to send the packet
         if(call AMSend.send(dest, &pkt, sizeof(pack)) ==SUCCESS){
            busy = TRUE;
            return SUCCESS;
         }else{
            dbg(GENERAL_CHANNEL,"The radio is busy\n");
            return FAIL;
         }
      }else{
         dbg(GENERAL_CHANNEL, "The radio is busy\n");
         return BUSY;
      }

      dbg(GENERAL_CHANNEL, "FAILED!?");
      return FAIL;
   }

   // Finish sending message, send another
   event void AMSend.sendDone(message_t* msg, error_t error){
      if(&pkt == msg){
         busy = FALSE;
         postSendTask();
      }
   }
}
