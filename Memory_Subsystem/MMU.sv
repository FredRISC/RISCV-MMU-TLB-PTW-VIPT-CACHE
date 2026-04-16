`timescale 1ps/1ps

// This Memory Management Unit (MMU) is responsible for V2P translation by looking up the TLB

`define XLEN 32
`define PAGE_WIDTH 12 // 4KB per page
`define TLB_SIZE 4096
`define PAGE_ID_WIDTH XLEN-PAGE_WIDTH

module MMU(
input clk,
input rst_n,
input flush,

// CPU interface
input [PAGE_ID_WIDTH-1:0] Virtual_Address_in,
input read_req_in,
input write_req_in,

// Memory Subsystem interface
output [XLEN-1:0] Physical_Address_out,
output Physical_Page_ID_valid_out, // PPN found in TLB; to cache and CPU
output Physical_Page_ID_Miss_out,  // This can be conneccted to the stall signal of the Cache
output Dirty_Fault_out,            // If true, trigger PTW to update PTE dirty bit

// Control Registers
input [31:0] satp_in,
output ptw_busy_out,

// PTW Memory Interface (Route to L2 Arbiter)
output ptw_mem_req_out,
output ptw_mem_write_out,
output [31:0] ptw_mem_addr_out,
output [31:0] ptw_mem_write_data_out,
input ptw_mem_data_valid_in,
input [31:0] ptw_mem_read_data_in

);
 
logic TLB_Virtual_Page_ID_in [PAGE_ID_WIDTH-1:0];
logic TLB_Virtual_Page_ID_valid_in;
logic TLB_access_write_in;
logic TLB_Physical_Page_ID_out [PAGE_ID_WIDTH-1:0];
logic TLB_Physical_Page_ID_valid_out;
logic TLB_Physical_Page_ID_Miss_out;
logic TLB_Dirty_Fault_out;

// Internal signals connecting PTW and TLB
logic ptw_fill_en;
logic [19:0] ptw_fill_virtual_page;
logic [19:0] ptw_fill_physical_page;
logic ptw_fill_dirty_bit;

assign TLB_Virtual_Page_ID_in = Virtual_Address_in[(XLEN-1)-:PAGE_ID_WIDTH]; // Get the upper (20) bits of the virtual address as page ID
assign TLB_Virtual_Page_ID_valid_in = read_req_in | write_req_in;
assign TLB_access_write_in = write_req_in;


TLB TLB_inst(
    .clk(clk),
    .rst_n(rst_n),
    .flush(flush),
    .Virtual_Page_ID_in(TLB_Virtual_Page_ID_in),
    .Virtual_Page_ID_valid_in(TLB_Virtual_Page_ID_valid_in),
    .access_write_in(TLB_access_write_in),
    .Physical_Page_ID_out(TLB_Physical_Page_ID_out),
    .Physical_Page_ID_valid_out(TLB_Physical_Page_ID_valid_out),
    .Physical_Page_ID_Miss_out(TLB_Physical_Page_ID_Miss_out), // if this is high, PTW needs to fetch the page table entry from memory and fill the TLB
    .Dirty_Fault_out(TLB_Dirty_Fault_out)
    .fill_en(ptw_fill_en),
    .fill_virtual_page(ptw_fill_virtual_page),
    .fill_physical_page(ptw_fill_physical_page),
    .fill_dirty_bit(ptw_fill_dirty_bit)
);

PTW PTW_inst(
    .clk(clk),
    .rst_n(rst_n),
    .TLB_Miss_in(TLB_Physical_Page_ID_Miss_out),
    .Dirty_Fault_in(TLB_Dirty_Fault_out),
    .Virtual_Address_in(Virtual_Address_in),
    .satp_in(satp_in),
    .fill_en_out(ptw_fill_en),
    .fill_virtual_page_out(ptw_fill_virtual_page),
    .fill_physical_page_out(ptw_fill_physical_page),
    .fill_dirty_bit_out(ptw_fill_dirty_bit),
    .ptw_busy_out(ptw_busy_out),
    .ptw_mem_req_out(ptw_mem_req_out),
    .ptw_mem_write_out(ptw_mem_write_out),
    .ptw_mem_addr_out(ptw_mem_addr_out),
    .ptw_mem_write_data_out(ptw_mem_write_data_out),
    .ptw_mem_data_valid_in(ptw_mem_data_valid_in),
    .ptw_mem_read_data_in(ptw_mem_read_data_in)
);

// Pass through the lower 12 bits (the page), because TLB take one cycle
logic [PAGE_WIDTH-1:0] Page_passthrough;
always @(posedge clk || negedge rst_n) begin
    if(!rst_n || flush) begin
        Page_passthrough <= 'd0;
    end
    else begin
        Page_passthrough <= Virtual_Address_in[PAGE_WIDTH-1:0];
    end
end

// output assignments
assign Physical_Address_out = {TLB_Physical_Page_ID_out ,Page_passthrough};
assign Physical_Page_ID_valid_out = TLB_Physical_Page_ID_valid_out; // To CPU (LSQ) so it can release the request and proceed to the next one
assign Physical_Page_ID_Miss_out = TLB_Physical_Page_ID_Miss_out;
assign Dirty_Fault_out = TLB_Dirty_Fault_out;


endmodule