from TestSim import TestSim

def main():
    s = TestSim()

    s.runTime(1)
    s.loadTopo("tuna-melt.topo")
    s.loadNoise("no_noise.txt")
    s.bootAll()

    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
    s.addChannel(s.TRANSPORT_CHANNEL)
    s.addChannel(s.TRANSPORT_TEST_CHANNEL)

    # Let ND/LS converge
    s.runTime(300)
    s.testServer(1)
    s.runTime(60)

    # Start two concurrent clients to the same server
    # Client 1: node 4 -> 1:123, src_port=204
    s.testClient(4)
    s.runTime(100)  # Delay to ensure first client command is processed and routing is stable
    
    # Client 2: node 5 -> 1:123, src_port=205
    s.testClient(5)

    # Run long enough for both clients to transfer data
    # s.runTime(2000)
    s.runTime(5000)

    # Close both connections cleanly
    s.cmdClose(4, 1, 204, 123)
    s.runTime(100)
    s.cmdClose(5, 1, 205, 123)
    s.runTime(200)

if __name__ == "__main__":
    main()

