#! /usr/bin/python
import sys
from TOSSIM import *
from CommandMsg import *

class TestSim:
    moteids=[]
    # COMMAND TYPES
    CMD_PING = 0
    CMD_NEIGHBOR_DUMP = 1
    CMD_ROUTE_DUMP=3
    CMD_TEST_CLIENT = 4
    CMD_TEST_SERVER = 5
    CMD_KILL = 6
    CMD_CLOSE = 7
    CMD_CHAT_HELLO = 10
    CMD_CHAT_MSG = 11
    CMD_CHAT_WHISPER = 12
    CMD_CHAT_LISTUSR = 13

    # CHANNELS - see includes/channels.h
    COMMAND_CHANNEL="command"
    GENERAL_CHANNEL="general"

    # Project 1
    NEIGHBOR_CHANNEL="neighbor"
    FLOODING_CHANNEL="flooding"

    # Project 2
    ROUTING_CHANNEL="routing"

    # Project 3
    TRANSPORT_CHANNEL="transport"
    PROJECT3_TGEN_CHANNEL="Project3TGen"

    # Project 4
    PROJECT4_CHAT_CHANNEL="Project4Chat"

    # Personal Debuggin Channels for some of the additional models implemented.
    HASHMAP_CHANNEL="hashmap"

    # Initialize Vars
    numMote=0

    def __init__(self):
        self.t = Tossim([])
        self.r = self.t.radio()

        #Create a Command Packet
        self.msg = CommandMsg()
        self.pkt = self.t.newPacket()
        self.pkt.setType(self.msg.get_amType())

    # Load a topo file and use it.
    def loadTopo(self, topoFile):
        print("Creating Topo!")
        # Read topology file.
        topoFile = 'topo/'+topoFile
        f = open(topoFile, "r")
        self.numMote = int(f.readline());
        print("Number of Motes"), self.numMote
        for line in f:
            s = line.split()
            if s:
                print(""), s[0], " ", s[1], " ", s[2];
                self.r.add(int(s[0]), int(s[1]), float(s[2]))
                if not int(s[0]) in self.moteids:
                    self.moteids=self.moteids+[int(s[0])]
                if not int(s[1]) in self.moteids:
                    self.moteids=self.moteids+[int(s[1])]

    # Load a noise file and apply it.
    def loadNoise(self, noiseFile):
        if self.numMote == 0:
            print("Create a topo first")
            return

        # Get and Create a Noise Model
        noiseFile = 'noise/'+noiseFile
        noise = open(noiseFile, "r")
        for line in noise:
            str1 = line.strip()
            if str1:
                val = int(str1)
            for i in self.moteids:
                self.t.getNode(i).addNoiseTraceReading(val)

        for i in self.moteids:
            print("Creating noise model for "),i
            self.t.getNode(i).createNoiseModel()

    def bootNode(self, nodeID):
        if self.numMote == 0:
            print("Create a topo first")
            return
        self.t.getNode(nodeID).bootAtTime(1333*nodeID)

    def bootAll(self):
        i=0
        for i in self.moteids:
            self.bootNode(i)

    def moteOff(self, nodeID):
        self.t.getNode(nodeID).turnOff()

    def moteOn(self, nodeID):
        self.t.getNode(nodeID).turnOn()

    def run(self, ticks):
        for i in range(ticks):
            self.t.runNextEvent()

    # Rough run time. tickPerSecond does not work.
    def runTime(self, amount):
        self.run(amount*1000)

    # Generic Command
    def sendCMD(self, ID, dest, payloadStr):
        self.msg.set_dest(dest)
        self.msg.set_id(ID)
        self.msg.setString_payload(payloadStr)

        self.pkt.setData(self.msg.data)
        self.pkt.setDestination(dest)
        self.pkt.deliver(dest, self.t.time()+5)

    def ping(self, source, dest, msg):
        self.sendCMD(self.CMD_PING, source, "{0}{1}".format(chr(dest),msg))

    def neighborDMP(self, destination):
        self.sendCMD(self.CMD_NEIGHBOR_DUMP, destination, "neighbor command")

    def routeDMP(self, destination):
        self.sendCMD(self.CMD_ROUTE_DUMP, destination, "routing command")

    def buildPayload(self, values):
        payload = ""
        for value in values:
            payload += chr((value >> 8) & 0xFF)
            payload += chr(value & 0xFF)
        return payload

    def cmdTestServer(self, address, port):
        payload = self.buildPayload([address, port])
        self.sendCMD(self.CMD_TEST_SERVER, address, payload)

    def cmdTestClient(self, client_addr, dest_addr, src_port, dest_port, transfer):
        payload = self.buildPayload([client_addr, dest_addr, src_port, dest_port, transfer])
        self.sendCMD(self.CMD_TEST_CLIENT, client_addr, payload)

    def cmdClose(self, client_addr, dest_addr, src_port, dest_port):
        payload = self.buildPayload([client_addr, dest_addr, src_port, dest_port])
        self.sendCMD(self.CMD_CLOSE, client_addr, payload)

    # Chat helper functions
    def padUsername(self, name):
        n = name[:12]
        return n + ("\x00" * (12 - len(n)))

    def chatHello(self, client_addr, username, clientPort):
        uname = self.padUsername(username)
        payload = uname + chr((clientPort >> 8) & 0xFF) + chr(clientPort & 0xFF)
        self.sendCMD(self.CMD_CHAT_HELLO, client_addr, payload)

    def chatMsg(self, client_addr, msg):
        self.sendCMD(self.CMD_CHAT_MSG, client_addr, msg[:25])

    def chatWhisper(self, client_addr, target_user, msg):
        uname = self.padUsername(target_user)
        self.sendCMD(self.CMD_CHAT_WHISPER, client_addr, uname + msg[:13])

    def chatListUsr(self, client_addr):
        self.sendCMD(self.CMD_CHAT_LISTUSR, client_addr, "")

    # Convenience wrappers used by testA/testB
    def testServer(self, address):
        # Use default port 123 for server tests
        self.cmdTestServer(address, 123)

    def testClient(self, client_addr):
        # Default: server at node 1, client_src_port based on client id, dest_port 123, transfer 1000
        dest_addr = 1
        src_port = 200 + client_addr  # simple per-client source port
        dest_port = 123
        transfer = 1000
        self.cmdTestClient(client_addr, dest_addr, src_port, dest_port, transfer)

    def addChannel(self, channelName, out=sys.stdout):
        print("Adding Channel")
        channelName
        self.t.addChannel(channelName, out)

def main():
    s = TestSim()
    s.runTime(10)
    s.loadTopo("long_line.topo")
    s.loadNoise("no_noise.txt")
    s.bootAll()

    # s.addChannel(s.COMMAND_CHANNEL)
    # s.addChannel(s.GENERAL_CHANNEL)
    # s.addChannel(s.FLOODING_CHANNEL)
    # s.addChannel(s.NEIGHBOR_CHANNEL)
    # s.addChannel(s.PROJECT3_TGEN_CHANNEL)
    s.addChannel(s.PROJECT4_CHAT_CHANNEL)

    # Allow routing to settle
    s.runTime(8000)

    # two clients (2=alice, 3=bob) to server node 1 port 41
    s.chatHello(2, "alice", 2002)
    s.runTime(400)
    s.chatHello(3, "bob", 2003)
    s.runTime(8000)

    # Early listusr to verify early in the session
    s.chatListUsr(2)
    s.runTime(8000)

    s.chatMsg(2, "hi-all")
    s.runTime(800)

    s.chatWhisper(3, "alice", "hi-alice")
    s.runTime(800)

    s.chatListUsr(2)
    s.runTime(2000)


if __name__ == '__main__':
    main()
