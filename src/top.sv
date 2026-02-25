module top(
	input  logic clk,
	input  logic reset,
	output logic test_done
);

  // Shared bus signals
  tri [127:0]   bus_data;      // 128-bit shared tri-state data bus
  tri [31:0]    bus_addr;      // 32-bit shared tri-state address bus
  tri [2:0]     bus_op;        // 3-bit shared tri-state operation bus
  tri           bus_valid;     // Shared response valid
  tri           bus_shared;    // Shared line indicator
  tri           bus_busy;      // Shared bus busy

  // L1 control signals
  logic [3:0]   l1_bus_req;    // Request from each L1
  logic [3:0]   l1_bus_grant;  // Grant to each L1

  // L1 to Processor Connections (32-bit word interface)
  logic [31:0]  l1_read_data   [3:0];
  logic         l1_ready       [3:0];
  logic         l1_cache_hit   [3:0];

  logic         l1_valid       [3:0];
  logic         l1_mem_write   [3:0];
  logic [31:0]  l1_data_adr    [3:0];
  logic [31:0]  l1_write_data  [3:0];

  // L2 <-> DRAM signals
  logic         l2_dram_valid;
  logic         l2_dram_write;
  logic [31:0]  l2_dram_addr;
  logic [127:0] l2_dram_wdata;
  logic [127:0] l2_dram_rdata;
  logic         l2_dram_ready;

  // Instantiate 4x L1 Caches
  generate
    for (genvar i = 0; i < 4; i = i + 1) begin : L1_INST
      L1 l1_cpu(
        .clk(clk),
        .reset(reset),
        .PID(i[1:0]),
        
        // CPU interface (32-bit words)
        .Valid(l1_valid[i]),
        .MemWrite(l1_mem_write[i]),
        .DataAdr(l1_data_adr[i]),
        .WriteData(l1_write_data[i]),
        .ReadData(l1_read_data[i]),
        .Ready(l1_ready[i]),
        .CacheHit(l1_cache_hit[i]),
        
        // Bus interface
        .BusGrant(l1_bus_grant[i]),
        .BusReq(l1_bus_req[i]),
        .Data(bus_data),
        .BusBusy(bus_busy),
        .BusValid(bus_valid),
        .BusShared(bus_shared),
        .BusAdr(bus_addr),
        .BusOp(bus_op)
      );
    end
  endgenerate

  // Instantiate L2 Cache
  L2 l2_cache(
    .clk(clk),
    .reset(reset),
    .dram_valid(l2_dram_valid),
    .dram_write(l2_dram_write),
    .dram_addr(l2_dram_addr),
    .dram_wdata(l2_dram_wdata),
    .dram_rdata(l2_dram_rdata),
    .dram_ready(l2_dram_ready),
    .Data(bus_data),
    .BusBusy(bus_busy),
    .BusValid(bus_valid),
    .BusShared(bus_shared),
    .BusAdr(bus_addr),
    .BusOp(bus_op)
  );

  // Instantiate backing DRAM
  dram main_memory(
    .clk(clk),
    .MemWrite(l2_dram_write),
    .Valid(l2_dram_valid),
    .DataAdr(l2_dram_addr),
    .WriteDataBlock(l2_dram_wdata),
    .ReadDataBlock(l2_dram_rdata),
    .Ready(l2_dram_ready)
  );

  // Instantiate Bus Arbiter
  Arbiter bus_arbiter(
    .clk(clk),
    .reset(reset),
    .BusReq(l1_bus_req),
    .BusGrant(l1_bus_grant),
    .BusBusy(bus_busy)
  );

  // Testbench Control
  assign test_done = 1'b0; // Will be set by testbench

endmodule

