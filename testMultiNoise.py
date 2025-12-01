from TestSim import TestSim

def main():
    s = TestSim()

    s.runTime(1)
    # Use multi-hop topology (pizza.topo has more nodes and longer paths)
    s.loadTopo("pizza.topo")
    # Use moderate noise (not as heavy as meyer-heavy, but still tests reliability)
    s.loadNoise("some_noise.txt")
    s.bootAll()

    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
    s.addChannel(s.TRANSPORT_CHANNEL)
    s.addChannel(s.PROJECT3_TGEN_CHANNEL)

    # Give routing extra time to converge under noise
    s.runTime(600)
    s.testServer(1)
    s.runTime(300)

    # Start two concurrent clients from different nodes
    # Client 1: node 4 -> 1:123, src_port=204 (multi-hop path)
    s.testClient(4)
    
    # Client 2: node 13 -> 1:123, src_port=213 (different multi-hop path)
    s.testClient(13)

    # Run long enough for both clients to transfer data through noisy network
    s.runTime(3000)

    # Close both connections cleanly
    s.cmdClose(4, 1, 204, 123)
    s.runTime(100)
    s.cmdClose(13, 1, 213, 123)
    s.runTime(200)

if __name__ == "__main__":
    main()

