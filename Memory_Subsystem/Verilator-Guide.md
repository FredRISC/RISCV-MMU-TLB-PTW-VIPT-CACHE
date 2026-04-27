# The Anatomy of a Verilator C++ Testbench:
### 
1. Include Headers: 
    Include verilated.h (core library), verilated_vcd_c.h (for waveform dumping), and VYourModule.h (the transpiled SV module).
2. Instantiate the DUT: 
    Create a pointer to the transpiled module: VL1Cache* dut = new VL1Cache;.
3. The Clock Loop: 
    Create a while loop that simulates time. Inside the loop, manually toggle the clock pin (dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval();).
4. Stimulus & Evaluation: 
    set posedge clk with dut->clk = 1; dut->eval(); set negedge clk with dut->clk = 0; dut->eval();
    set input pins (e.g., dut->load_req_in = 1;) right before the rising edge, and read output pins right after.
    dut->eval(): When changing an input pin (e.g., dut->load_req_in = 1;), nothing actually happens yet. When calling dut->eval(), Verilator runs all of the always_comb blocks. When flipping dut->clk = 1 and call eval(), it executes all the always_ff blocks.


# Verification Plan:
###
    Phase 1: L1 Cache Standalone (Coalesced Load Miss)
    Goal: Verify basic MSHR allocation, load misses to same block, the block returns, and finally output the lsq vector.
    Test: Assert multiple load requests and respectively feed a physical tag directly to the cache a cycle later, wait for the SimulatedMemory class to return data several cycles later, and observe the lsq_wakeup_vector_out.

    Phase 2: Advanced L1 Cache (Store Coalescing & PLRU eviction)
    Goal: Verify the Store Buffer correctly merges byte-enabled writes and that dirty lines are written back upon PLRU eviction.
    Test: Issue multiple store reqs to a line for coalescing and Load three blocks into the same set so the LRU line is the dirty line. Afterwards, we load a line to the set to evict and write back the dirty line.

    Phase 3: MMU & PTW Standalone
    Goal: Verify that providing a virtual address to the MMU triggers a TLB Miss, starts the PTW FSM, fetches L1/L0 PTEs from memory, and fills the TLB.
    Test: Drive the target virtual page number to MMU to trigger TLB lookup and miss. After TLB misses, it will send a request to PTW and wait for the response, and cting as main memory, the testbench drives the PTE (mock page table walking) to PTW after a few cycles. (both Sv32's L1 and L0 PTE)
    The PTW will then fill the TLB entry, so the CPU can retry the request and get the physical tag in the next cycle. Page fault is also tested.

    Phase 4: Full System Integration
    Goal: Connect the MMU and Cache together in Verilator. The testbench acts as the CPU (sending VAs) and the L2 Memory Arbiter

# Commands to run Verilator and Generate the makefile:
### 
    verilator -Wall --cc --trace L1Cache.sv --exe tb_L1Cache.cpp -Wno-fatal
    make -j -C obj_dir -f VL1Cache.mk
    ./obj_dir/VL1Cache