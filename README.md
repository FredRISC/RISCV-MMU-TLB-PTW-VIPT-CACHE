# RISC-V Sv32 Non-Blocking Memory Subsystem

An out-of-order capable memory subsystem prototype written in SystemVerilog. This project implements a Virtually Indexed, Physically Tagged (VIPT) L1 Data Cache (D-Cache), a fully associative Micro-TLB, and a Hardware Page Table Walker (PTW) implementing the core **RISC-V Sv32** Virtual Memory architecture and a subset of the **Svadu** hardware dirty-bit extension.

## Key Architectural Features

### 1. VIPT Non-Blocking L1 Data Cache
* **Virtually Indexed, Physically Tagged (VIPT):** Prevents cache aliasing by utilizing a 4KB cache size (4-way set associative) where the virtual index bits directly map to physical index bits.
* **Miss Status Handling Registers (MSHR):** Supports non-blocking execution. A 16-entry MSHR allows the cache to continue servicing hits while fetching up to 16 concurrent cache line misses from the L2/Main Memory.
* **Store Coalescing Buffer:** A 4-entry Store Buffer captures and merges sub-word writes to the same cache line, resolving structural hazards upon L2 block return and supporting D-Cache semantics.
* **Tree-based Pseudo-LRU (PLRU):** Implements a mathematical binary-tree PLRU eviction policy, supporting generic number of ways.

### 2. RISC-V Sv32 & Svadu Core Feature Integration
* **Fully Associative Micro-TLB:** A 64-entry Translation Lookaside Buffer for single-cycle virtual-to-physical address translation.
* **Hardware Page Table Walker (PTW):** An explicit multi-state FSM that automatically traverses 2-level RISC-V Sv32 page tables in hardware using the `satp` CSR base address.
* **Svadu Hardware Dirty-Bit Management:** Natively detects writes to clean pages (Store Page Faults). The PTW stalls the L1 D-Cache write, proactively updates the leaf PTE's dirty bit in main memory, and transparently updates the TLB. *(Note: The Accessed 'A' bit and static R/W/X permissions are omitted to scope the prototype around the more complex datapath update mechanisms).*
* **Context Switch Datapath Hooks:** Implements global hardware flush mechanisms to immediately invalidate TLB entries and dynamically abort active PTW state machines, supporting `sfence.vma` instruction execution.
* **Page Fault Exceptions:** Dynamically evaluates PTE Valid (`V`) and Permission bits, raising architectural Page Faults back to the CPU trap handler.

---

## Interface Assumptions & Subsystem Logistics

This subsystem is designed to interface with a superscalar Out-of-Order (OoO) CPU utilizing a Load/Store Queue (LSQ).

1. **Address Translation:** 
   * The CPU sends the virtual index to the L1 VIPT D-Cache and concurrently sends the Virtual Page Number (Bits 31:12) to the **MMU/TLB** for physical page number lookup.
2. **Tag Resolution & Cache Lookup:** 
   * The TLB outputs the translated Physical Tag.
   * Upon TLB `valid` assertion, the **L1 D-Cache** uses the Virtual Index to read the flip-flop based cache array and combinationally compares the Physical Tag against the 4 active ways in the set.
3. **Stall & Replay Mechanics:**
   * If a TLB Miss or Dirty Fault occurs, the MMU drops the `valid` flag.
   * The CPU LSQ is expected to **hold** the request until TLB returns the physivasl tag. On TLB Miss, the hardware PTW takes over the memory bus, resolves the fault, and backfills the TLB. On the following cycle, the translation succeeds and the cache seamlessly resumes.
4. **Wakeup Vectors:**
   * Upon L2 miss returns, the MSHR generates a 1-cycle `lsq_wakeup_vector` corresponding to the exact LSQ IDs waiting for the data, allowing the CPU to schedule the load instructions for execution.

---

## File Structure

* `MMU.sv` - Top-level Memory Management wrapper and CPU-facing interface.
* `TLB.sv` - 64-entry fully associative Micro-TLB with parallel read/fill ports.
* `PTW.sv` - FSM-based Hardware Page Table Walker (Sv32 2-level traversal).
* `L1Cache.sv` - 4KB VIPT Cache with MSHR, Store Buffer, and PLRU eviction.

## To-Do / Future Expansion
* Create a Verilator C++ Testbench to mock CPU LSQ stimulus and randomized L2 memory delays.
* **VIPT Pipelining Optimization:** Replace the flip-flop based Cache Array with synchronous SRAM macros, pipelining the SRAM index read to execute in parallel with the TLB lookup to optimize the critical path.
* **Standardized Interconnects:** Migrate the L2 Memory / Bus interface to utilize standard **AMBA AXI4** or **TileLink** valid/ready handshaking protocols, including a bus arbiter to multiplex PTW memory walks and L1 Cache evictions.