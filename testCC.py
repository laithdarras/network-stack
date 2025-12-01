from TestSim import TestSim

def main():
    s = TestSim()

    s.runTime(1)
    s.loadTopo("tuna-melt.topo")
    s.loadNoise("no_noise.txt")
    s.bootAll()

    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.TRANSPORT_CHANNEL)
    s.addChannel(s.PROJECT3_TGEN_CHANNEL)

    # Let ND/LS converge (same as testA scale)
    s.runTime(300)
    s.testServer(1)
    s.runTime(60)

    # Single TCP client: node 4 -> 1:123, transfer=1000 (same as testA)
    s.testClient(4)

    # Run long enough to see cwnd growth and full transfer
    s.runTime(2000)

    # Close cleanly
    s.cmdClose(4, 1, 204, 123)
    s.runTime(200)

if __name__ == "__main__":
    main()

