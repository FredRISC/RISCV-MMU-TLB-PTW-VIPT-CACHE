# VIPT Non-Blocking L1 D-Cache & RISC-V MMU Memory Subsystem

An out-of-order capable memory subsystem prototype written in SystemVerilog. This project implements a Virtually Indexed, Physically Tagged (VIPT) L1 Data Cache (D-Cache), a fully associative Micro-TLB, and a Hardware Page Table Walker (PTW) implementing the core **RISC-V Sv32** Virtual Memory architecture (including ASID and Global bit support) along with full **Svadu** (Hardware A/D Bit Management) compliance.

## Key Architectural Features

### 1. VIPT Non-Blocking L1 Data Cache
* **Virtually Indexed, Physically Tagged (VIPT):** Prevents cache aliasing by utilizing a 4KB cache size (4-way set associative) where the virtual index bits directly map to physical index bits.
* **Miss Status Handling Registers (MSHR):** Supports non-blocking execution. A 16-entry MSHR allows the cache to continue servicing hits while fetching up to 16 concurrent cache line misses from the L2/Main Memory.
* **Store Coalescing Buffer:** A 4-entry Store Buffer captures and merges sub-word writes to the same cache line, resolving structural hazards upon L2 block return and supporting D-Cache semantics.
* **Tree-based Pseudo-LRU (PLRU):** Implements a mathematical binary-tree PLRU eviction policy, supporting generic number of ways.

### 2. RISC-V MMU Memory Subsystem with Core Feature Integration of Sv32 & Svadu
* **Fully Associative Micro-TLB:** A 64-entry Translation Lookaside Buffer for single-cycle virtual-to-physical address translation.
* **Hardware Page Table Walker (PTW):** An explicit multi-state FSM that automatically traverses 2-level RISC-V Sv32 page tables in hardware using the `satp` CSR base address.
* **Svadu Hardware Management (A/D Bit Updates):** Fully compliant with the RISC-V Svadu extension. The hardware natively detects reads to unaccessed pages and writes to clean pages. Upon detection, the PTW stalls the L1 D-Cache, proactively performs memory accesses to set the leaf PTE's Access (A) and Dirty (D) bits in main memory, and transparently backfills the updated state into the TLB. 
* **Context Switch & ASID Support:** Implements Address Space Identifiers (ASID) and Global (G) bits within TLB entries to differentiate process ownership and preserve shared global pages across context switches. Features hardware flush mechanisms to selectively invalidate TLB entries by Virtual Address and/or ASID, fully supporting fine-grained `sfence.vma rs1, rs2` execution and dynamically aborting active PTW state machines.
* **Page Fault Exceptions:** Dynamically evaluates PTE Valid (`V`) bit, raising architectural Page Faults back to the CPU trap handler.

## Interface Assumptions & Subsystem Logistics

This subsystem is designed to interface with a superscalar Out-of-Order (OoO) CPU utilizing a Load/Store Queue (LSQ).

1. **Address Translation:** 
   * The CPU sends the virtual index to the L1 VIPT D-Cache and concurrently sends the Virtual Page Number (Bits 31:12) to the **MMU/TLB** for physical page number lookup.
2. **Tag Resolution & Cache Lookup:** 
   * The TLB outputs the translated Physical Tag.
   * Upon TLB `valid` assertion, the **L1 D-Cache** uses the Virtual Index to read the flip-flop based cache array and combinationally compares the Physical Tag against the 4 active ways in the set.
3. **Stall & Replay Mechanics:**
   * If a TLB Miss or Dirty Fault occurs, the MMU drops the `valid` flag.
   * The CPU LSQ is expected to **hold** the request until the TLB returns the physical tag. On TLB Miss, the hardware PTW takes over the memory bus, resolves the fault, and backfills the TLB. On the following cycle, the translation succeeds and the cache seamlessly resumes.
4. **Wakeup Vectors:**
   * Upon L2 miss returns, the MSHR generates a 1-cycle `lsq_wakeup_vector` corresponding to the exact LSQ IDs waiting for the data, allowing the CPU to schedule the load instructions for execution.

---

## File Structure

* `MMU.sv` - Top-level Memory Management wrapper and CPU-facing interface.
* `TLB.sv` - 64-entry fully associative Micro-TLB with parallel read/fill ports.
* `PTW.sv` - FSM-based Hardware Page Table Walker (Sv32 2-level traversal).
* `L1Cache.sv` - 4KB VIPT Cache with MSHR, Store Buffer, and PLRU eviction.

## Future Roadmap / Advanced Design Implementation
* Create a Verilator C++ Testbench to mock CPU LSQ stimulus and randomized L2 memory delays.
* **Standardized Interconnects:** Migrate the L2 Memory / Bus interface to utilize standard **AMBA AXI4** or **TileLink-C** valid/ready handshaking protocols, including a bus arbiter to multiplex PTW memory walks and L1 Cache evictions.
* **VIPT Pipelining Optimization:** Replace the flip-flop based Cache Array with synchronous SRAM macros, pipelining the SRAM index read to execute in parallel with the TLB lookup to optimize the critical path.
* **Full Privileged Spec Compliance:** 
  * **PMP & Access Faults:** Implement a Physical Memory Protection (PMP) unit between the MMU and the Interconnect to intercept and block illegal hardware accesses, raising explicit Store/Load Access Faults.
  * **Permission Exceptions:** Enforce `R/W/X/U` bit verification against the current CPU privilege level, trapping on Store/Load/Instruction Page Faults.
  * **Megapage Support:** Update the PTW FSM to evaluate `R/W/X` bits at the L1 level, supporting 4MB Leaf PTEs to short-circuit the page walk.