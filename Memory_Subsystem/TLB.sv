`timescale 1ps/1ps

// Translation Lookaside - structure that store V2P mapping
// Internal to the MMU

`define XLEN 32
`define PAGE_WIDTH 12 // 4KB per page
`define TLB_SIZE 64   // Industry standard size for a fully associative L1 (Micro) TLB
`define PAGE_ID_WIDTH XLEN-PAGE_WIDTH

module TLB(
//global signals
input clk,
input rst_n,
input flush, // sfence.vma or any other event that requires flushing the TLB

// TLB core signals, from CPU (assuming CPU holds the request until TLB response is ready with Physical_Page_ID_valid_out asserted)
input [PAGE_ID_WIDTH-1:0] Virtual_Page_ID_in,
input Virtual_Page_ID_valid_in, // Asserted if either read or write request is active
input req_type_in,          // 1 if it is a write operation, 0 if read

// TLB output to MMU (to Cache and CPU)
output [PAGE_ID_WIDTH-1:0] Physical_Page_ID_out,
output Physical_Page_ID_valid_out, // to CPU, so CPU can proceed to next request
output Physical_Page_ID_Miss_out,  // PPN not found in TLB, trigger PTW to fetch the page table entry from memory and fill the TLB
output Dirty_Fault_out,         // Asserted when a write hits a clean page (needs PTW to set dirty bit in memory)

// PTW-TLB Fill Interface
input fill_en,
input [PAGE_ID_WIDTH-1:0] fill_virtual_page,
input [PAGE_ID_WIDTH-1:0] fill_physical_page,
input fill_dirty_bit // set to 1 if the page is written
);

// TLB entry struct
typedef struct packed {
    logic [PAGE_ID_WIDTH-1:0] Virtual_Page_ID;
    logic [PAGE_ID_WIDTH-1:0] Physical_Page_ID;
    logic valid;
    logic dirty;
} TLB_t;

TLB_t TLB_Entries [TLB_SIZE-1:0];
logic Virtual_Page_ID_Miss_flag;
logic TLB_Dirty_Fault_flag;
logic [$clog2(TLB_SIZE)-1:0] TLB_Dirty_Fault_index;

logic [PAGE_ID_WIDTH-1:0] Physical_Page_ID_read;
logic [$clog2(TLB_SIZE)-1:0] replace_ptr; // simple round-robin replacement

// TLB lookup logic (Replace with CAM for better performance)
always_comb begin
    Virtual_Page_ID_Miss_flag = 1'b1;
    TLB_Dirty_Fault_flag = 1'b0;
    TLB_Dirty_Fault_index = 'd0; // Default to prevent inferred latch
    if(Virtual_Page_ID_valid_in) begin
        for(int i=0;i < TLB_SIZE;i = i+1) begin
            if(Virtual_Page_ID_in == TLB_Entries[i].Virtual_Page_ID && TLB_Entries[i].valid) begin // TLB hit
                if (req_type_in && !TLB_Entries[i].dirty) begin // store request comes in, requiring the TLB entry to be dirty
                    TLB_Dirty_Fault_flag = 1'b1; // if its clean, then raise dirty fault flag for PTW to update the corresponding PTE's dirty bit
                    TLB_Dirty_Fault_index = i;
                end 
                else begin
                    Virtual_Page_ID_Miss_flag = 1'b0;
                    Physical_Page_ID_read = TLB_Entries[i].Physical_Page_ID;
                end
                break;
            end
        end
    end
end

always @(posedge clk || negedge rst_n) begin
    if(!rst_n || flush) begin
        Physical_Page_ID_out <= 'd0;
        Physical_Page_ID_valid_out <= 1'b0;
        Physical_Page_ID_Miss_out <= 1'b0;
        Dirty_Fault_out <= 1'b0;
        replace_ptr <= 'd0;
        for(int i = 0; i < TLB_SIZE; i++) begin
            TLB_Entries[i].valid <= 1'b0;
        end
    end
    else begin
        if (fill_en) begin
            // Update TLB entry on a miss fill
            if(Virtual_Page_ID_Miss_flag == 1'b1) begin  // this flag remains high because the CPU hold the request
                TLB_Entries[replace_ptr].Virtual_Page_ID <= fill_virtual_page;
                TLB_Entries[replace_ptr].Physical_Page_ID <= fill_physical_page;
                TLB_Entries[replace_ptr].valid <= 1'b1;
                TLB_Entries[replace_ptr].dirty <= fill_dirty_bit;
                replace_ptr <= replace_ptr + 1'b1;
            end
            else if(TLB_Dirty_Fault_flag == 1'b1) begin 
                TLB_Entries[TLB_Dirty_Fault_index].Physical_Page_ID <= fill_physical_page; 
                TLB_Entries[TLB_Dirty_Fault_index].dirty <= fill_dirty_bit;
            end        
        end
        
        if(Virtual_Page_ID_valid_in) begin
            if(TLB_Dirty_Fault_flag == 1'b1) begin // Dirty fault takes priority over miss, so OS won't discard the page memory space and assign to other processes (silently corrupted when Cache write back)
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