module Arbiter(
	input		logic			clk,
  input		logic			reset,
	input		logic	[3:0]	BusReq,
	output	logic	[3:0]	BusGrant,
	inout		logic			BusBusy
);

  // Round-robin pointer: which L1 gets next priority
  logic [1:0] grant_pointer;
  logic [3:0] grant_reg;
  logic [3:0] grant_next;

  always_comb begin
    grant_next = grant_reg;

    // If current owner still requests, keep bus locked
    if (|grant_reg) begin
      if ((grant_reg & BusReq) == 4'b0000) begin
        grant_next = 4'b0000;
      end
    end

    // If bus is free, choose next requester by round-robin
    if (grant_next == 4'b0000) begin
      for (int i = 0; i < 4; i = i + 1) begin
        if (BusReq[(grant_pointer + i[1:0]) & 2'b11] && grant_next == 4'b0000) begin
          grant_next[(grant_pointer + i[1:0]) & 2'b11] = 1'b1;
        end
      end
    end
  end

  assign BusGrant = grant_reg;

  always_ff @(posedge clk) begin
    if (reset) begin
      grant_pointer <= 2'b00;
      grant_reg <= 4'b0000;
    end else begin
      grant_reg <= grant_next;

      // Advance pointer when a new owner is granted
      if (grant_reg == 4'b0000 && grant_next != 4'b0000) begin
        for (int i = 0; i < 4; i = i + 1) begin
          if (grant_next[i]) begin
            grant_pointer <= i[1:0] + 2'b01; // Next L1 in round-robin
          end
        end
      end
    end
  end

  // BusBusy is driven by any L1 when it has a grant and is actively transacting
  // This is a tri-state signal; each L1 can drive it low when busy
  assign BusBusy = 1'bz; // Tri-state: L1s will drive when needed

endmodule