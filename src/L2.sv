module L2(
	input		logic				clk,
	input		logic				reset,
  // DRAM backing store interface
  output	logic				dram_valid,
  output	logic				dram_write,
  output	logic	[31:0]	dram_addr,
  output	logic	[127:0]	dram_wdata,
  input		logic	[127:0]	dram_rdata,
  input		logic				dram_ready,
	// L2 connections
	inout		logic	[127:0]	Data,
	inout		logic				BusBusy, BusValid, BusShared,
	inout		logic	[31:0]	BusAdr,
	inout		logic	[2:0]		BusOp
);

  // Per-block L2 storage (inclusive: holds all L1 lines)
  typedef struct packed {
    logic        valid;
    logic [18:0] tag;
    logic [3:0]  l1_sharers;    // Which L1s have this block (1=has it)
    logic [127:0] data;
  } l2_block_t;

  // L2: 256 blocks @ 256 -> total of 72KB (but 16KB per L1, so 4x coverage)
  // For simple simulation, use 512 blocks like L1 (easier address matching)
  l2_block_t L2_SRAM [511:0];

  // Address decomposition for bus snooping
  logic [18:0] bus_tag;
  logic [8:0]  bus_index;
  assign bus_tag = BusAdr[31:13];
  assign bus_index = BusAdr[12:4];

  logic bus_shared_r;  // Registered version of BusShared (for protocol tracking only)
  
  always_ff @(posedge clk) begin
    bus_shared_r <= BusShared;
  end

  // Tri-state bus drivers (inout nets must be driven via continuous assign)
  logic [127:0] data_out;
  logic         data_oe;
  logic         busvalid_out;
  logic         busvalid_oe;
  logic         busshared_out;
  logic         busshared_oe;

  assign Data = (data_oe === 1'b1) ? data_out : 128'hz;
  assign BusValid = (busvalid_oe === 1'b1) ? busvalid_out : 1'bz;
  assign BusShared = (busshared_oe === 1'b1) ? busshared_out : 1'bz;

  logic bus_txn_active;
  logic dram_pending;
  logic [18:0] dram_pending_tag;
  logic [8:0] dram_pending_index;
  logic [31:0] dram_pending_busadr;

  logic [31:0] block_word_addr;
  assign block_word_addr = {BusAdr[31:4], 4'b0000};

  always_comb begin
    bus_txn_active = 1'b0;
    if (!$isunknown(BusOp) && !$isunknown(BusAdr)) begin
      bus_txn_active = (BusOp === 3'b000) || (BusOp === 3'b001) || (BusOp === 3'b010) || (BusOp === 3'b011);
    end
  end

  // L2 passive snoop/respond logic
  always_comb begin
    data_out = 128'h0;
    data_oe = 1'b0;
    busvalid_out = 1'b0;
    busvalid_oe = 1'b0;
    busshared_out = 1'b0;
    busshared_oe = 1'b0;
    dram_valid = 1'b0;
    dram_write = 1'b0;
    dram_addr = 32'h0;
    dram_wdata = 128'h0;

    // L2 responds passively to bus transactions (BusRd/BusRdX/BusUpgr)
    if (bus_txn_active) begin
      if (BusOp === 3'b000 || BusOp === 3'b001) begin // BusRd or BusRdX
        logic other_cache_responding;
        other_cache_responding = (BusShared === 1'b1);

        // If we already launched a DRAM read for this transaction, wait for it
        if (dram_pending && (dram_pending_busadr == {BusAdr[31:4], 4'b0000})) begin
          if (dram_ready) begin
            if (!other_cache_responding) begin
              data_out = $isunknown(dram_rdata) ? 128'h0 : dram_rdata;
              data_oe = 1'b1;
            end
            busvalid_out = 1'b1;
            busvalid_oe = 1'b1;
          end
        end else begin
          // No pending DRAM fetch: try L2 hit first
          if (L2_SRAM[bus_index].valid && L2_SRAM[bus_index].tag == bus_tag) begin
            if (!other_cache_responding) begin
              data_out = $isunknown(L2_SRAM[bus_index].data) ? 128'h0 : L2_SRAM[bus_index].data;
              data_oe = 1'b1;
            end
            busvalid_out = 1'b1;
            busvalid_oe = 1'b1;
          end else begin
            // L2 miss: fetch from DRAM backing store
            if (!other_cache_responding) begin
              dram_valid = 1'b1;
              dram_write = 1'b0;
              dram_addr = block_word_addr;
            end else begin
              // Another L1 is supplying data this cycle; acknowledge bus transaction
              busvalid_out = 1'b1;
              busvalid_oe = 1'b1;
            end
          end
        end

        // Assert BusShared if WE have multiple sharers (L1s already handle their BusShared)
        if (L2_SRAM[bus_index].valid && L2_SRAM[bus_index].tag == bus_tag &&
            |L2_SRAM[bus_index].l1_sharers) begin
          busshared_out = 1'b1;
          busshared_oe = 1'b1;
        end
      end else if (BusOp === 3'b010) begin // BusUpgr
        busvalid_out = 1'b1;
        busvalid_oe = 1'b1;
      end else if (BusOp === 3'b011) begin // Writeback from L1
        // Accept writeback and push to DRAM + L2
        dram_valid = 1'b1;
        dram_write = 1'b1;
        dram_addr = block_word_addr;
        dram_wdata = $isunknown(Data) ? 128'h0 : Data;
        busvalid_out = 1'b1;
        busvalid_oe = 1'b1;
      end
    end
  end

  integer i;
  always_ff @(posedge clk) begin
    if (reset) begin
      dram_pending <= 1'b0;
      dram_pending_tag <= 19'h0;
      dram_pending_index <= 9'h0;
      dram_pending_busadr <= 32'h0;
      for (i = 0; i < 512; i = i + 1) begin
        L2_SRAM[i].valid <= 1'b0;
        L2_SRAM[i].tag <= 19'h0;
        L2_SRAM[i].l1_sharers <= 4'b0000;
        L2_SRAM[i].data <= 128'h0;
      end
    end else begin
      // Start tracking a DRAM read when miss fetch is initiated
      if (bus_txn_active && (BusOp === 3'b000 || BusOp === 3'b001) &&
          !dram_pending && !(L2_SRAM[bus_index].valid && L2_SRAM[bus_index].tag == bus_tag)) begin
        dram_pending <= 1'b1;
        dram_pending_tag <= bus_tag;
        dram_pending_index <= bus_index;
        dram_pending_busadr <= {BusAdr[31:4], 4'b0000};
      end

      // Complete pending DRAM read: install in L2
      if (dram_pending && dram_ready) begin
        L2_SRAM[dram_pending_index].valid <= 1'b1;
        L2_SRAM[dram_pending_index].tag <= dram_pending_tag;
        L2_SRAM[dram_pending_index].data <= $isunknown(dram_rdata) ? 128'h0 : dram_rdata;
        dram_pending <= 1'b0;
      end

      // Update L2 from bus transactions when data is available (cache-to-cache fill)
      if (bus_txn_active && !$isunknown(Data) && (BusOp === 3'b000 || BusOp === 3'b001)) begin
        L2_SRAM[bus_index].valid <= 1'b1;
        L2_SRAM[bus_index].tag <= bus_tag;
        L2_SRAM[bus_index].data <= Data;
      end

      // Update L2 on explicit writeback op
      if (bus_txn_active && BusOp === 3'b011 && !$isunknown(Data)) begin
        L2_SRAM[bus_index].valid <= 1'b1;
        L2_SRAM[bus_index].tag <= bus_tag;
        L2_SRAM[bus_index].data <= Data;
      end
    end
  end

endmodule
