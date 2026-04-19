`timescale 1ps/1ps

// This Memory Management Unit (MMU) is responsible for V2P translation by looking up the TLB
// A Page Table Walker (PTW) is also included to handle TLB miss, Dirty fault, and Page fault

`define XLEN 32
`define PAGE_WIDTH 12 // 4KB per page
`define TLB_SIZE 64
`define PAGE_ID_WIDTH XLEN-PAGE_WIDTH

`define CacheLineSize 64   // 64 bytes per line
`define L1CacheSize 2**12 // 4KB
`define NUM_OF_LINES L1CacheSize/CacheLineSize //2**6 = 64 cache lines
`define NUM_OF_WAYS 4     // 4-way associative cache
`define NUM_OF_SETS  L1CacheSize/ (NUM_OF_WAYS*CacheLineSize)

`define INDEX_BITS $clog2(NUM_OF_SETS)
`define OFFSET_BITS $clog2(CacheLineSize)
`define TAG_BITS XLEN - INDEX_BITS - OFFSET_BITS

module MMU(
input clk,
input rst_n,
input flush,

// CPU interface
input [PAGE_ID_WIDTH-1:0] Virtual_Address_in,
input read_req_in,
input write_req_in,

// Core output interface
output [TAG_BITS-1:0] physical_tag_out, // The Physical Tag translated by TLB to be passed to the VIPT L1 Cache
output physical_tag_valid_out, // Valid flag for the output physical tag; to both CPU and L1 Cache
output Physical_Page_ID_Miss_out,  // debug: TLB miss flag from TLB
output page_fault_out, // Signals the CPU to take a trap (pass control to OS)

// Control Registers
input [31:0] satp_in, // RISC-V CSR storing the base address of the L1 PTE frame of a process
output ptw_busy_out, // debug: PTW is currently walking

// PTW-Memory Interface (Route to L2 Arbiter)
output ptw_mem_req_valid_out,
output ptw_mem_req_type_out, // 1 for write, 0 for read
output [31:0] ptw_mem_addr_out, // physical memory address of a L1 PTE, a L0 PTE or of the translated physical address to be filled into TLB 
output [31:0] ptw_mem_write_data_out, // for updating the dirty bit of the PTE 
input ptw_mem_data_valid_in, 
input [31:0] ptw_mem_read_data_in // The returned L1 PTE, L0 PTE or the translated physical address

);
 
logic [PAGE_ID_WIDTH-1:0] TLB_Virtual_Page_ID_in;
logic TLB_Virtual_Page_ID_valid_in;
logic TLB_req_type_in;
logic [PAGE_ID_WIDTH-1:0] TLB_Physical_Page_ID_out;
logic TLB_Physical_Page_ID_valid_out;
logic TLB_Physical_Page_ID_Miss_out;
logic TLB_Dirty_Fault_out;
logic TLB_Miss_req_type_in;

// Internal signals connecting PTW and TLB
logic ptw_fill_en;
logic [19:0] ptw_fill_virtual_page;
logic [19:0] ptw_fill_physical_page;
logic ptw_fill_dirty_bit;

assign TLB_Virtual_Page_ID_in = Virtual_Address_in[(XLEN-1)-:PAGE_ID_WIDTH]; // Get the upper (20) bits of the virtual address as page ID
assign TLB_Virtual_Page_ID_valid_in = read_req_in | write_req_in;
assign TLB_req_type_in = write_req_in;
assign TLB_Miss_req_type_in = write_req_in;


TLB TLB_inst(
    .clk(clk),
    .rst_n(rst_n),
    .flush(flush), 
    .Virtual_Page_ID_in(TLB_Virtual_Page_ID_in),
    .Virtual_Page_ID_valid_in(TLB_Virtual_Page_ID_valid_in),
    .req_type_in(TLB_req_type_in),
    .Physical_Page_ID_out(TLB_Physical_Page_ID_out),
    .Physical_Page_ID_valid_out(TLB_Physical_Page_ID_valid_out),
    .Physical_Page_ID_Miss_out(TLB_Physical_Page_ID_Miss_out), // if this is high, PTW needs to fetch the page table entry from memory and fill the TLB
    .Dirty_Fault_out(TLB_Dirty_Fault_out),
    .fill_en(ptw_fill_en),
    .fill_virtual_page(ptw_fill_virtual_page),
    .fill_physical_page(ptw_fill_physical_page),
    .fill_dirty_bit(ptw_fill_dirty_bit)
);

PTW PTW_inst(
    .clk(clk),
    .rst_n(rst_n),
    .flush(flush),
    .TLB_Miss_in(TLB_Physical_Page_ID_Miss_out), // core input: Miss flag from TLB 
    .TLB_Miss_req_type_in(TLB_Miss_req_type_in), // core input: Request type of the TLB miss 
    .Dirty_Fault_in(TLB_Dirty_Fault_out),        // core input: Dirty fault flag from TLB 
    .Virtual_Address_in(Virtual_Address_in),     // core input: virtual address used for PTE offset in L1 and L0 PTE frames
    .satp_in(satp_in),                           // core input: satp CSR that store the the PPN of the Root Page Table
    .fill_en_out(ptw_fill_en),
    .fill_virtual_page_out(ptw_fill_virtual_page),
    .fill_physical_page_out(ptw_fill_physical_page),
    .fill_dirty_bit_out(ptw_fill_dirty_bit),
    .page_fault_out(page_fault_out),             
    .ptw_busy_out(ptw_busy_out),                 // debug: PTW is currently walking; not in IDLE state
    .ptw_mem_req_valid_out(ptw_mem_req_valid_out),
    .ptw_mem_req_type_out(ptw_mem_req_type_out),
    .ptw_mem_addr_out(ptw_mem_addr_out),
    .ptw_mem_write_data_out(ptw_mem_write_data_out),
    .ptw_mem_data_valid_in(ptw_mem_data_valid_in),
    .ptw_mem_read_data_in(ptw_mem_read_data_in)
);


// output assignments
assign physical_tag_out = TLB_Physical_Page_ID_out[(PAGE_ID_WIDTH-1)-:TAG_BITS];
assign physical_tag_valid_out = TLB_Physical_Page_ID_valid_out; // To CPU (LSQ) so it can release the request and proceed to the next one

endmodule

/*
Ensured RISC-V architectural compliance by supporting sfence.vma instructions, implementing hardware flush mechanisms to invalidate the TLB and dynamically abort active Page Table Walks to maintain memory consistency.
*/