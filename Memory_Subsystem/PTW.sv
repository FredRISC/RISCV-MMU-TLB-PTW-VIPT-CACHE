`timescale 1ps/1ps

// RISC-V Sv32 Hardware Page Table Walker (PTW)

/* 
    RISC-V Sv32 Page Table Entry (PTE) Format (32 bits total):
    | 31...................10 | 9.......8 | 7 | 6 | 5 | 4 | 3 | 2 | 1 | 0 |
    | Physical Page Num (PPN) | Reserved  | D | A | G | U | X | W | R | V |
    
    V = Valid (1 if page is in memory, 0 if not allocated or on disk)
    R, W, X = Read, Write, Execute permissions
    U = User mode accessible
    G = Global mapping
    A = Accessed (Hardware sets to 1 when read/written)
    D = Dirty (Hardware sets to 1 when written)
*/

module PTW (
    input clk,
    input rst_n,
    input flush,

    // MMU / TLB Interface
    input TLB_Miss_in,
    input TLB_Miss_req_type_in,
    input Dirty_Fault_in,
    input [31:0] Virtual_Address_in,
    
    // Control Registers
    input [31:0] satp_in, // Contains the PPN (Physical Page Number) of the Root Page Table

    // Output back to TLB
    output logic fill_en_out,
    output logic [19:0] fill_virtual_page_out,
    output logic [19:0] fill_physical_page_out,
    output logic fill_dirty_bit_out,
    output logic page_fault_out, // Raised to CPU if V=0 or permission denied
    output logic ptw_busy_out, // debug: PTW is currently walking; not in IDLE state

    // Memory Interface
    output logic ptw_mem_req_valid_out,
    output logic ptw_mem_req_type_out,
    output logic [31:0] ptw_mem_addr_out,
    output logic [31:0] ptw_mem_write_data_out,
    input ptw_mem_data_valid_in,
    input [31:0] ptw_mem_read_data_in
);

    // State Machine encoding
    typedef enum logic [3:0] {
        IDLE,
        REQ_L1_PTE,                 // IDLE -> REQ_L1_PTE, on TLB Miss or Dirty Fault
        WAIT_L1_PTE,                // REQ_L1_PTE -> WAIT_L1_PTE, after sending memory request for L1 PTE
        REQ_L0_PTE,                 // WAIT_L1_PTE -> REQ_L0_PTE, after receiving L1 PTE and checking its validity
        WAIT_L0_PTE,                // REQ_L0_PTE -> WAIT_L0_PTE, after sending memory request for L0 PTE
        UPDATE_DIRTY_BIT,           // WAIT_L0_PTE -> UPDATE_DIRTY_BIT, after receiving L0 PTE and if dirty fault is detected
        WAIT_UPDATE,                
        FILL_TLB,
        PAGE_FAULT                  // Trap state if PTE is invalid. Waits for pipeline flush.
    } ptw_state_t;

    ptw_state_t state, next_state;

    // Internal registers to hold addresses and PTEs
    logic [31:0] current_va;
    logic is_dirty_fault;
    logic is_write_req;
    logic [31:0] l1_pte; // PTE read from L1 page table (l1_pte = MEM[satp*4KB+VPN1*4])
    logic [31:0] l0_pte; // PTE read from L0 page table (MEM[l1_pte*4KB + VPN0*4])
    
    // Sv32 Virtual Address breakdown
    logic [9:0] vpn1; // 10-bit Virtual Page Number [31:22]
    logic [9:0] vpn0; // 10-bit Virtual Page Number [21:12]
    assign vpn1 = current_va[31:22];
    assign vpn0 = current_va[21:12];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            state <= IDLE;
            current_va <= '0;
            is_dirty_fault <= 1'b0;
            l1_pte <= '0;
            l0_pte <= '0;
        end else begin
            state <= next_state;
            
            // NOTE: WE DON'T NEED THIS IF BLOCK. THIS IS ONLY FOR TRACKING PER PTW REQUEST (TLB MISS or DIRTY FAULT)
            if (state == IDLE && (TLB_Miss_in || Dirty_Fault_in)) begin
                current_va <= Virtual_Address_in; // Latch the virtual address for the entire PTW process
                is_dirty_fault <= Dirty_Fault_in; // Latch the dirty fault signal to determine if we need to set the dirty bit in the PTE later
                is_write_req <= TLB_Miss_req_type_in; // Latch the write request signal
            end
            
            if (state == WAIT_L1_PTE && ptw_mem_data_valid_in) begin
                l1_pte <= ptw_mem_read_data_in; // Latch the L1 PTE since it is transient
            end

            if (state == WAIT_L0_PTE && ptw_mem_data_valid_in) begin
                l0_pte <= ptw_mem_read_data_in; // Latch the L0 PTE since it is transient
            end
        end
    end

    always_comb begin
        // Defaults
        next_state = state;
        ptw_mem_req_valid_out = 1'b0;
        ptw_mem_req_type_out = 1'b0;
        ptw_mem_addr_out = '0;
        ptw_mem_write_data_out = '0;
        
        fill_en_out = 1'b0;
        fill_virtual_page_out = '0;
        fill_physical_page_out = '0;
        fill_dirty_bit_out = 1'b0;
        ptw_busy_out = 1'b1;
        page_fault_out = 1'b0;

        case (state)
            IDLE: begin
                ptw_busy_out = 1'b0;
                if (TLB_Miss_in || Dirty_Fault_in) begin
                    next_state = REQ_L1_PTE;
                end
            end

            REQ_L1_PTE: begin
                ptw_mem_req_valid_out = 1'b1;
                // L1 PTE Address = (satp * 4KB) + (VPN1 * 4)
                ptw_mem_addr_out = {satp_in[19:0], 12'b0} + {20'b0, vpn1, 2'b00}; // Page base address + offset to the PTE within the page
                next_state = WAIT_L1_PTE;
            end

            WAIT_L1_PTE: begin
                if (ptw_mem_data_valid_in) begin
                    // Check Valid bit (bit 0)
                    if (!ptw_mem_read_data_in[0]) begin
                        next_state = PAGE_FAULT;
                    end else begin
                        next_state = REQ_L0_PTE;
                    end
                end
            end

            REQ_L0_PTE: begin
                ptw_mem_req_valid_out = 1'b1;
                // L0 PTE Address = (L1_PTE.PPN * 4KB) + (VPN0 * 4)
                ptw_mem_addr_out = {l1_pte[29:10], 12'b0} + {20'b0, vpn0, 2'b00}; // Page base address + offset to the PTE within the page
                next_state = WAIT_L0_PTE;
            end

            WAIT_L0_PTE: begin
                if (ptw_mem_data_valid_in) begin
                    if (!ptw_mem_read_data_in[0]) begin // If the L0 PTE is invalid, then the process is trying to access illegal address
                        next_state = PAGE_FAULT;
                    end 
                    else if (is_dirty_fault || (!ptw_mem_read_data_in[7] && is_write_req)) begin // PTE[7] is Dirty bit
                        next_state = UPDATE_DIRTY_BIT;
                    end 
                    else begin
                        next_state = FILL_TLB;
                    end
                end
            end

            UPDATE_DIRTY_BIT: begin // update the dirty bit
                ptw_mem_req_valid_out = 1'b1;
                ptw_mem_req_type_out = 1'b1; // the request is a write request if this is 1'b1
                ptw_mem_addr_out = {l1_pte[29:10], 12'b0} + {20'b0, vpn0, 2'b00};
                // Set the Dirty Bit (bit 7) to 1
                ptw_mem_write_data_out = l0_pte | 32'h0000_0080;
                next_state = WAIT_UPDATE;
            end

            WAIT_UPDATE: begin // Wait until dirty bit is written to the L0 PTE
                if (ptw_mem_data_valid_in) begin
                    next_state = FILL_TLB;
                end
            end

            FILL_TLB: begin
                fill_en_out = 1'b1;
                fill_virtual_page_out = current_va[31:12];
                fill_physical_page_out = l0_pte[29:10]; // PPN from L0 PTE
                fill_dirty_bit_out = (is_dirty_fault || is_write_req)? 1'b1 : l0_pte[7];
                next_state = IDLE;
            end

            PAGE_FAULT: begin
                page_fault_out = 1'b1;
                // Wait here until the CPU takes the trap and asserts `flush`, which will reset the state machine to IDLE via the sequential block
            end

            default: next_state = IDLE;
        endcase
    end
endmodule