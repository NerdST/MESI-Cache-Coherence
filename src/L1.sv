module L1(
	input		logic				clk,
  input		logic				reset,
	// L1 to Processor Connections (32-bit word interface)
	input		logic	[1:0]		PID,
	input		logic				Valid, MemWrite,
	input		logic	[31:0]	DataAdr,
	input		logic	[31:0]	WriteData,
	output	logic	[31:0]	ReadData,
	output	logic				Ready, CacheHit,
	// L1 to L2 Connections
	input		logic				BusGrant,
	output	logic				BusReq,
	inout		logic	[127:0]	Data,
	inout		logic				BusBusy, BusValid, BusShared,
	inout		logic	[31:0]	BusAdr,
	inout		logic	[2:0]		BusOp
);

  // MESI states
  typedef enum logic [1:0] {
    INVALID,
    SHARED,
    EXCLUSIVE,
    MODIFIED
  } mesi_t;

  // Controller FSM state (orchestrates multi-cycle transactions)
  typedef enum logic [2:0] {
    IDLE,                  // Ready for new CPU request
    REQUEST_BUFFERED,      // Request latched, checking cache
    MISS_PENDING,          // L1 miss, waiting for bus grant
    BUS_ACTIVE,            // Bus granted, waiting for response
    WRITEBACK_PENDING      // Need to evict dirty block first
  } ctrl_t;

  ctrl_t ctrl_state, ctrl_next;

  // Cache storage
  typedef struct packed {
    mesi_t       mesi_state;    // Per-block MESI state
    logic        dirty;
    logic [18:0] tag;
    logic [127:0] data;
  } block_t;

  block_t SRAM [511:0];

  // CPU Request Buffer (holds one request while processing)
  logic [31:0] req_addr;
  logic [31:0] req_wdata;  // 32-bit word from CPU
  logic req_write;
  logic req_valid;

  // Write-back Buffer (one dirty block pending eviction)
  logic [31:0] wb_addr;
  logic [127:0] wb_data;
  logic wb_pending;

  // Address decomposition for incoming CPU request
  logic [18:0] new_tag;
  logic [8:0]  new_index;
  logic [1:0]  new_offset;
  assign new_tag = DataAdr[31:13];
  assign new_index = DataAdr[12:4];
  assign new_offset = DataAdr[3:2];

  // Address decomposition for buffered request (being processed)
  logic [18:0] req_tag;
  logic [8:0]  req_index;
  logic [1:0]  req_offset;
  assign req_tag = req_addr[31:13];
  assign req_index = req_addr[12:4];
  assign req_offset = req_addr[3:2];

  // Address decomposition for bus snooping
  logic [18:0] bus_tag;
  logic [8:0]  bus_index;
  assign bus_tag = BusAdr[31:13];
  assign bus_index = BusAdr[12:4];

  // Hit/Miss detection on currently buffered request
  logic cache_hit_comb;
  assign cache_hit_comb = req_valid && 
                          (SRAM[req_index].mesi_state != INVALID) && 
                          (SRAM[req_index].tag == req_tag);

  // Tri-state bus drivers (inout nets must be driven via continuous assign)
  logic [2:0]   busop_out;
  logic         busop_oe;
  logic [31:0]  busadr_out;
  logic         busadr_oe;
  logic [127:0] data_out;
  logic         data_oe;
  logic         busshared_out;
  logic         busshared_oe;

  logic         bus_txn_active;

  assign BusOp = (busop_oe === 1'b1) ? busop_out : 3'bz;
  assign BusAdr = (busadr_oe === 1'b1) ? busadr_out : 32'hz;
  assign Data = (data_oe === 1'b1) ? data_out : 128'hz;
  assign BusShared = (busshared_oe === 1'b1) ? busshared_out : 1'bz;

  always_comb begin
    bus_txn_active = 1'b0;
    if (!$isunknown(BusOp) && !$isunknown(BusAdr)) begin
      bus_txn_active = (BusOp === 3'b000) || (BusOp === 3'b001) || (BusOp === 3'b010) || (BusOp === 3'b011);
    end
  end

  // Combinational next-state and bus control logic
  always_comb begin : StateTransitionLogic
    ctrl_next = ctrl_state;
    CacheHit = 1'b0;      // Status: is buffered request a hit?
    Ready = 1'b0;         // Handshake: is buffered request complete?
    ReadData = 32'h0;     // 32-bit word output
    BusReq = 1'b0;
    busop_out = 3'b000;
    busop_oe = 1'b0;
    busadr_out = 32'h0;
    busadr_oe = 1'b0;
    data_out = 128'h0;
    data_oe = 1'b0;
    busshared_out = 1'b0;
    busshared_oe = 1'b0;

    case (ctrl_state)
      IDLE: begin
        // Accept new request from CPU if Valid
        if (Valid) begin
          ctrl_next = REQUEST_BUFFERED;
        end
      end

      REQUEST_BUFFERED: begin
        // Determine hit/miss on buffered request
        if (cache_hit_comb) begin
          CacheHit = 1'b1;
          // Extract requested 32-bit word from 128-bit block using address offset
          case (req_offset)
            2'b00: ReadData = SRAM[req_index].data[31:0];
            2'b01: ReadData = SRAM[req_index].data[63:32];
            2'b10: ReadData = SRAM[req_index].data[95:64];
            2'b11: ReadData = SRAM[req_index].data[127:96];
          endcase

          if (req_write) begin
            // Write hit - check if state allows local write
            if (SRAM[req_index].mesi_state == EXCLUSIVE || 
                SRAM[req_index].mesi_state == MODIFIED) begin
              // Can write locally without bus
              Ready = 1'b1;
              ctrl_next = IDLE;
            end else if (SRAM[req_index].mesi_state == SHARED) begin
              // Must upgrade via bus (BusUpgr)
              ctrl_next = MISS_PENDING;
              BusReq = 1'b1;
            end
          end else begin
            // Read hit - always ready
            Ready = 1'b1;
            ctrl_next = IDLE;
          end
        end else begin
          // Cache miss - check if writeback needed
          if (SRAM[req_index].dirty && SRAM[req_index].mesi_state != INVALID) begin
            // Dirty block in target way; must evict first
            ctrl_next = WRITEBACK_PENDING;
          end else begin
            // Clean or invalid way; can proceed to fetch
            ctrl_next = MISS_PENDING;
          end
        end
      end

      WRITEBACK_PENDING: begin
        // Request bus to push dirty line to L2/DRAM first
        BusReq = 1'b1;
        if (BusGrant && wb_pending) begin
          busadr_out = wb_addr;
          busadr_oe = 1'b1;
          busop_out = 3'b011; // Writeback
          busop_oe = 1'b1;
          data_out = wb_data;
          data_oe = 1'b1;
          ctrl_next = BUS_ACTIVE;
        end
      end

      MISS_PENDING: begin
        // Request bus for miss or upgrade
        BusReq = 1'b1;
        
        // Only drive bus address and operation signals when we have bus grant
        if (BusGrant) begin
          busadr_out = req_addr;
          busadr_oe = 1'b1;
          if (cache_hit_comb && req_write) begin
            busop_out = 3'b010; // BusUpgr
          end else begin
            busop_out = req_write ? 3'b001 : 3'b000; // BusRdX or BusRd
          end
          busop_oe = 1'b1;
          ctrl_next = BUS_ACTIVE;
        end
      end

      BUS_ACTIVE: begin
        // Bus granted; hold transaction until response
        BusReq = 1'b1;
        if (wb_pending) begin
          // Writeback phase
          busadr_out = wb_addr;
          busadr_oe = 1'b1;
          busop_out = 3'b011; // Writeback
          busop_oe = 1'b1;
          data_out = wb_data;
          data_oe = 1'b1;
        end else begin
          // Request phase
          busadr_out = req_addr;  // Keep address on bus
          busadr_oe = 1'b1;
          if (cache_hit_comb && req_write) begin
            busop_out = 3'b010; // BusUpgr
          end else begin
            busop_out = req_write ? 3'b001 : 3'b000;
          end
          busop_oe = 1'b1;
        end

        if (BusValid === 1'b1) begin
          if (wb_pending) begin
            // Writeback acknowledged; now fetch/request target line
            ctrl_next = MISS_PENDING;
          end else begin
            // Response arrived: complete transaction and release bus
            Ready = 1'b1;
            ctrl_next = IDLE;
          end
        end
      end
    endcase

    // Snoop Logic (only when NOT handling own transaction)
    if (bus_txn_active && ctrl_state != BUS_ACTIVE &&
      SRAM[bus_index].mesi_state != INVALID &&
      SRAM[bus_index].tag == bus_tag) begin
      case (SRAM[bus_index].mesi_state)
        SHARED: begin
          if (BusOp == 3'b000) begin // BusRd
            data_out = $isunknown(SRAM[bus_index].data) ? 128'h0 : SRAM[bus_index].data; // Supply clean shared data
            data_oe = 1'b1;
            busshared_out = 1'b1; // Indicate we have a copy
            busshared_oe = 1'b1;
          end else if (BusOp == 3'b001) begin // BusRdX
            data_out = $isunknown(SRAM[bus_index].data) ? 128'h0 : SRAM[bus_index].data; // Supply clean data before invalidation
            data_oe = 1'b1;
            busshared_out = 1'b1; // Indicate we had a copy
            busshared_oe = 1'b1;
          end
          // BusRdX and BusUpgr: invalidate in sequential
        end

        EXCLUSIVE: begin
          if (BusOp == 3'b000) begin // BusRd
            data_out = $isunknown(SRAM[bus_index].data) ? 128'h0 : SRAM[bus_index].data; // Supply clean exclusive data
            data_oe = 1'b1;
            busshared_out = 1'b1; // Will downgrade to SHARED
            busshared_oe = 1'b1;
          end else if (BusOp == 3'b001) begin // BusRdX
            data_out = $isunknown(SRAM[bus_index].data) ? 128'h0 : SRAM[bus_index].data; // Supply clean data before invalidation
            data_oe = 1'b1;
            busshared_out = 1'b1; // Indicate we had a copy
            busshared_oe = 1'b1;
          end
          // BusRdX: invalidate in sequential
        end

        MODIFIED: begin
          if (BusOp == 3'b000) begin // BusRd
            data_out = $isunknown(SRAM[bus_index].data) ? 128'h0 : SRAM[bus_index].data; // Supply modified data
            data_oe = 1'b1;
            busshared_out = 1'b1;            // Going to SHARED
            busshared_oe = 1'b1;
          end else if (BusOp == 3'b001) begin // BusRdX
            data_out = $isunknown(SRAM[bus_index].data) ? 128'h0 : SRAM[bus_index].data; // Supply modified data, then invalid
            data_oe = 1'b1;
            busshared_out = 1'b1;
            busshared_oe = 1'b1;
          end
        end
      endcase
    end
  end

  // Sequential logic (on clock edge)
  integer i;
  always_ff @(posedge clk) begin
    if (reset) begin
      ctrl_state <= IDLE;
      req_valid <= 1'b0;
      wb_pending <= 1'b0;

      for (i = 0; i < 512; i = i + 1) begin
        SRAM[i].mesi_state <= INVALID;
        SRAM[i].dirty <= 1'b0;
        SRAM[i].tag <= 19'h0;
        SRAM[i].data <= 128'h0;
      end
    end else begin
      // Advance controller FSM
      ctrl_state <= ctrl_next;

      // Buffer incoming CPU request
      if (ctrl_state == IDLE && Valid) begin
        req_addr <= DataAdr;
        req_wdata <= WriteData;  // FIXED: was WriteDataBlock
        req_write <= MemWrite;
        req_valid <= 1'b1;
      end

      // Clear buffered request when transaction completes
      if ((ctrl_state == REQUEST_BUFFERED || ctrl_state == MISS_PENDING || 
           ctrl_state == BUS_ACTIVE) && ctrl_next == IDLE) begin
        req_valid <= 1'b0;
      end

      // Process hit operations on buffered request
      if (ctrl_state == REQUEST_BUFFERED && cache_hit_comb && req_write &&
          (SRAM[req_index].mesi_state == EXCLUSIVE || 
           SRAM[req_index].mesi_state == MODIFIED)) begin
        SRAM[req_index].mesi_state <= MODIFIED;
        SRAM[req_index].dirty <= 1'b1;
        // Update only the requested 32-bit word within the 128-bit block
        case (req_offset)
          2'b00: SRAM[req_index].data[31:0] <= req_wdata;
          2'b01: SRAM[req_index].data[63:32] <= req_wdata;
          2'b10: SRAM[req_index].data[95:64] <= req_wdata;
          2'b11: SRAM[req_index].data[127:96] <= req_wdata;
        endcase
      end

      // Writeback buffer capture
      if (ctrl_state == REQUEST_BUFFERED && !cache_hit_comb &&
          SRAM[req_index].dirty && SRAM[req_index].mesi_state != INVALID &&
          wb_pending == 1'b0) begin
        // Capture dirty block into writeback buffer
        wb_addr <= {SRAM[req_index].tag, req_index, 4'b0000};
        wb_data <= SRAM[req_index].data;
        wb_pending <= 1'b1;
      end

      // Clear writeback pending once writeback transaction is acknowledged
      if (ctrl_state == BUS_ACTIVE && wb_pending && BusValid === 1'b1) begin
        wb_pending <= 1'b0;
      end

      // Handle bus response (miss fill or upgrade response)
      if (ctrl_state == BUS_ACTIVE && !wb_pending && BusValid === 1'b1) begin
        if (req_write) begin
          if (cache_hit_comb) begin
            // BusUpgr response: keep existing cache line contents
            SRAM[req_index].tag <= req_tag;
          end else begin
            // Write miss response: install fetched line first
            SRAM[req_index].tag <= req_tag;
            if ($isunknown(Data)) begin
              SRAM[req_index].data <= 128'h0;
            end else begin
              SRAM[req_index].data <= Data;
            end
          end

          // Merge CPU write word into selected 32-bit lane
          case (req_offset)
            2'b00: SRAM[req_index].data[31:0] <= req_wdata;
            2'b01: SRAM[req_index].data[63:32] <= req_wdata;
            2'b10: SRAM[req_index].data[95:64] <= req_wdata;
            2'b11: SRAM[req_index].data[127:96] <= req_wdata;
          endcase

          SRAM[req_index].mesi_state <= MODIFIED;
          SRAM[req_index].dirty <= 1'b1;
        end else begin
          SRAM[req_index].tag <= req_tag;
          if ($isunknown(Data)) begin
            SRAM[req_index].data <= 128'h0;
          end else begin
            SRAM[req_index].data <= Data;
          end
          // Determine final state based on BusShared
          SRAM[req_index].mesi_state <= (BusShared === 1'b1) ? SHARED : EXCLUSIVE;
          SRAM[req_index].dirty <= 1'b0;
        end
      end

      // Snoop-induced state transitions
          if (bus_txn_active && ctrl_state != BUS_ACTIVE &&
          SRAM[bus_index].mesi_state != INVALID &&
          SRAM[bus_index].tag == bus_tag) begin
        case (SRAM[bus_index].mesi_state)
          SHARED, EXCLUSIVE, MODIFIED: begin
            if (BusOp == 3'b001) begin // BusRdX
              SRAM[bus_index].mesi_state <= INVALID;
            end else if (BusOp == 3'b010) begin // BusUpgr
              SRAM[bus_index].mesi_state <= INVALID;
            end else if (BusOp == 3'b000 && SRAM[bus_index].mesi_state == EXCLUSIVE) begin
              // BusRd: EXCLUSIVE → SHARED
              SRAM[bus_index].mesi_state <= SHARED;
            end else if (BusOp == 3'b000 && SRAM[bus_index].mesi_state == MODIFIED) begin
              // BusRd: MODIFIED → SHARED (data now on bus, clear dirty locally)
              SRAM[bus_index].mesi_state <= SHARED;
              SRAM[bus_index].dirty <= 1'b0;
            end
          end
        endcase
      end
    end
  end

endmodule