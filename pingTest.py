from TestSim import TestSim

def main():
    s = TestSim()

    # Load network layout and noise model
    s.loadTopo("long_line.topo")
    s.loadNoise("no_noise.txt")
    s.bootAll()

    # Add logging channels
    # s.addChannel(s.COMMAND_CHANNEL)
    # s.addChannel(s.GENERAL_CHANNEL)
    # s.addChannel(s.ROUTING_CHANNEL)
    # # s.addChannel(s.FLOODING_CHANNEL)
    s.addChannel("Transport")

    # Run long enough for TCP timer to fire (5 seconds) and routing to converge
    s.runTime(30)

    # s.routeDMP(4)
    # s.runTime(10)
    # s.ping(16,4,"")
    # s.runTime(10)
    # s.moteOff(9)
    # s.runTime(100)
    # s.ping(5,10,"")
    # s.runTime(10)
    # s.routeDMP(7)
    # s.runTime(10)

if __name__ == '__main__':
    main()