`timescale 1ps/1ps

// Fully Associative micro-Translation Lookaside Buffer (Internal to the MMU) - structure that store V2P mapping.
// Note that TLB's permission flags (R, W, X, U) and A bit are ignored, and we assume all pages are RWX and Access bit is 1.

`define XLEN 32
`define PAGE_WIDTH 12 // 4KB per page
`define TLB_SIZE 64   // 64-entry fully associative L1 (Micro) TLB
`define PAGE_ID_WIDTH `XLEN-`PAGE_WIDTH

module TLB(
//global signals
input clk,
input rst_n,
input flush, // sfence.vma or any other event that requires flushing the TLB
input [31:0] flush_vaddr_in, 
input [8:0] flush_asid_in,
input flush_vaddr_valid_in, 
input flush_asid_valid_in,

// TLB core signals, from CPU (assuming CPU holds the request until TLB response is ready with Physical_Page_ID_valid_out asserted)
input [`PAGE_ID_WIDTH-1:0] Virtual_Page_ID_in,
input Virtual_Page_ID_valid_in, // Asserted if either read or write request is active
input req_type_in,          // 1 if it is a write operation, 0 if read
input [31:0] satp_in, // for future extension to support ASID 

// TLB output to MMU (to Cache and CPU)
output logic [`PAGE_ID_WIDTH-1:0] Physical_Page_ID_out,
output logic Physical_Page_ID_valid_out, // to CPU, so CPU can proceed to next request
output logic Physical_Page_ID_Miss_out,  // PPN not found in TLB, trigger PTW to fetch the page table entry from memory and fill the TLB
output logic Dirty_Fault_out,         // Asserted when a write hits a clean page (needs PTW to set dirty bit in memory)

// PTW-TLB Fill Interface
input fill_en,
input [`PAGE_ID_WIDTH-1:0] fill_virtual_page,
input [`PAGE_ID_WIDTH-1:0] fill_physical_page,
input fill_dirty_bit // set to 1 if the page is written
);

// TLB entry struct
typedef struct packed {
    logic [`PAGE_ID_WIDTH-1:0] Virtual_Page_ID;
    logic [`PAGE_ID_WIDTH-1:0] Physical_Page_ID;
    logic valid;
    logic dirty;
    logic global;
    logic [8:0] asid; // In Sv32, the satp.ASID field is 9 bits wide (bits 30–22)
    // logic [2:0] Flags; // permission bits, not implemented in this version, but can be used for future extension (R, W, X, A, U. G)
} TLB_t;

TLB_t TLB_Entries [`TLB_SIZE-1:0];
logic Virtual_Page_ID_Miss_flag;
logic TLB_Dirty_Fault_flag;
logic [$clog2(`TLB_SIZE)-1:0] TLB_Dirty_Fault_index;

logic [`PAGE_ID_WIDTH-1:0] Physical_Page_ID_read;
logic [$clog2(`TLB_SIZE)-1:0] replace_ptr; // simple round-robin replacement

// TLB lookup logic (Replace with CAM for better performance)
always_comb begin
    Virtual_Page_ID_Miss_flag = 1'b1;
    TLB_Dirty_Fault_flag = 1'b0;
    TLB_Dirty_Fault_index = '0;
    Physical_Page_ID_read = '0;
    if(Virtual_Page_ID_valid_in) begin
        for(int i=0;i < `TLB_SIZE;i = i+1) begin
            if(Virtual_Page_ID_in == TLB_Entries[i].Virtual_Page_ID && TLB_Entries[i].valid && (TLB_Entries[i].global || (TLB_Entries[i].asid == satp_in[30:22]))) begin // TLB hit
                if (req_type_in && !TLB_Entries[i].dirty) begin // TLB hits but it's clean while the request is a write
                    TLB_Dirty_Fault_flag = 1'b1; // raise a dirty fault to trigger PTW to set the dirty bit in memory
                    TLB_Dirty_Fault_index = i;   // record the TLB entry index
                end 
                else begin
                    // TLB hit! Prepare the PPN output
                    Virtual_Page_ID_Miss_flag = 1'b0;
                    Physical_Page_ID_read = TLB_Entries[i].Physical_Page_ID;
                end
                break;
            end
        end
    end
end


always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        Physical_Page_ID_out <= 'd0;
        Physical_Page_ID_valid_out <= 1'b0;
        Physical_Page_ID_Miss_out <= 1'b0;
        Dirty_Fault_out <= 1'b0;
        replace_ptr <= 'd0;
        for(int i = 0; i < `TLB_SIZE; i++) begin
            TLB_Entries[i] <= '{default: '0};
        end
    end
    else if (flush) begin
        // Clear output flags during a flush
        Physical_Page_ID_valid_out <= 1'b0;
        Physical_Page_ID_Miss_out <= 1'b0;
        Dirty_Fault_out <= 1'b0;
        // Fine-grained invalidation matching
        for(int i = 0; i < `TLB_SIZE; i++) begin
            if (TLB_Entries[i].valid) begin                
                /*
                    sfence.vma x0, x0: "Flush all VPNs for all ASIDs." (Global flush, used at boot or major state changes).
                    sfence.vma x0, a0: "Flush all VPNs for the ASID stored in a0." (Used during context switches when killing a process. We must preserve Global pages).
                    sfence.vma a1, x0: "Flush the specific VPN in a1 for all ASIDs." (Used when unmapping a shared memory region).
                */

                // sfence.vma a1, x0: Flush the specific VPN in a1 for all ASIDs.
                if((flush_vaddr_valid_in && (TLB_Entries[i].Virtual_Page_ID == flush_vaddr_in[31:12])) && !flush_asid_valid_in) begin
                    TLB_Entries[i] <= '{default: '0};
                end
                
                // sfence.vma x0, a0: Flush all VPNs for the ASID stored in a0, but global pages must be preserved.
                if(!flush_vaddr_valid_in && (flush_asid_valid_in && (TLB_Entries[i].asid == flush_asid_in))) begin
                    if(!TLB_Entries[i].global) TLB_Entries[i] <= '{default: '0};
                end
                
                // sfence.vma a1, a0: Flush the specific VPN in a1 for the ASID stored in a0, but global pages must be preserved.
                if(flush_vaddr_valid_in && flush_asid_valid_in && (TLB_Entries[i].Virtual_Page_ID == flush_vaddr_in[31:12]) && (TLB_Entries[i].asid == flush_asid_in)) begin
                    if(!TLB_Entries[i].global) TLB_Entries[i] <= '{default: '0}; 
                end

                // flush all TLB entries
                if(!flush_vaddr_valid_in && !flush_asid_valid_in) begin
                    TLB_Entries[i] <= '{default: '0};
                end
            end
        end
        
    end
    else begin
        if (fill_en) begin
            // Update TLB entry on a miss fill
            if(Virtual_Page_ID_Miss_flag == 1'b1) begin  // this flag remains high because the CPU hold the request
                TLB_Entries[replace_ptr].Virtual_Page_ID <= fill_virtual_page;
                TLB_Entries[replace_ptr].Physical_Page_ID <= fill_physical_page;
                TLB_Entries[replace_ptr].valid <= 1'b1;
                TLB_Entries[replace_ptr].dirty <= fill_dirty_bit; // Even when a new entry is filled due to a miss, it can be dirty if the fill is triggered by a store request; we proactively set the dirty bit on TLB miss.
                TLB_Entries[replace_ptr].global <= 1'b0;          // set as non-global entry by default
                TLB_Entries[replace_ptr].asid <= satp_in[30:22];  // Identify the process for this TLB entry using ASID from satp register
                replace_ptr <= replace_ptr + 1'b1;
            end
            else if(TLB_Dirty_Fault_flag == 1'b1) begin 
                TLB_Entries[TLB_Dirty_Fault_index].Physical_Page_ID <= fill_physical_page; 
                TLB_Entries[TLB_Dirty_Fault_index].dirty <= fill_dirty_bit;
            end        
        end
        Physical_Page_ID_valid_out <= 1'b0;
        if(Virtual_Page_ID_valid_in) begin
            if(TLB_Dirty_Fault_flag == 1'b1) begin // Dirty fault takes priority over miss, so OS won't discard the physical frame and assign to other processes (silently corrupted when Cache write back)
                Dirty_Fault_out <= 1'b1;
                Physical_Page_ID_Miss_out <= 1'b0;
                Physical_Page_ID_valid_out <= 1'b0;
            end
            else if(Virtual_Page_ID_Miss_flag == 1'b1) begin
                Physical_Page_ID_Miss_out <= 1'b1;
                Physical_Page_ID_valid_out <= 1'b0;
                Dirty_Fault_out <= 1'b0;
            end
            else begin
                Physical_Page_ID_out <= Physical_Page_ID_read;
                Physical_Page_ID_Miss_out <= 1'b0;
                Dirty_Fault_out <= 1'b0;
                Physical_Page_ID_valid_out <= 1'b1;
            end
        end
    end
end


endmodule