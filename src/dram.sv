module dram(
  input logic        clk,
  input logic        MemWrite, Valid,
  input logic [31:0] DataAdr,
  input logic [127:0] WriteDataBlock,
  output logic [127:0] ReadDataBlock,
  output logic        Ready
);
  logic [31:0] DRAM [1048575:0];
  integer i;

  initial begin
    Ready = 1'b0;
    ReadDataBlock = 128'h0;
    for (i = 0; i < 1048576; i = i + 1) begin
      DRAM[i] = 32'h0;
    end
  end

  always @(posedge clk) begin
    if (Valid) begin
      if (MemWrite) begin
        // Write 4 words (128 bits) as a block
        DRAM[DataAdr]      <= WriteDataBlock[31:0];
        DRAM[DataAdr + 1]  <= WriteDataBlock[63:32];
        DRAM[DataAdr + 2]  <= WriteDataBlock[95:64];
        DRAM[DataAdr + 3]  <= WriteDataBlock[127:96];
      end else begin
        // Read 4 words (128 bits) as a block
        ReadDataBlock[31:0]   <= DRAM[DataAdr];
        ReadDataBlock[63:32]  <= DRAM[DataAdr + 1];
        ReadDataBlock[95:64]  <= DRAM[DataAdr + 2];
        ReadDataBlock[127:96] <= DRAM[DataAdr + 3];
      end
      Ready <= 1;
    end else begin
      Ready <= 0;
    end
  end
endmodule