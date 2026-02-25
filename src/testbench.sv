`timescale 1ns/1ps

module testbench();

  logic clk;
  logic reset;
  logic test_done;
  int sim_cycle;

  // Instantiate top-level module
  top dut(
    .clk(clk),
    .reset(reset),
    .test_done(test_done)
  );

  // Clock generation
  always begin
    clk = 1'b0; #5;
    clk = 1'b1; #5;
  end

  // DEBUG - Monitor bus transactions specifically for BusRdX
  always_ff @(posedge clk) begin
    if (dut.bus_op === 3'b001) begin
      $display("    [BUS] BusRdX adr=0x%h shared=%b valid=%b data=%h", 
               dut.bus_addr, dut.bus_shared, dut.bus_valid, dut.bus_data);
    end
  end

  always @(posedge clk) begin
    sim_cycle <= sim_cycle + 1;
  end

  // Test vector structure
  // ADDRESS (32-bit hex) _ MEMWRITE (0/1) _ L1_ID (0-3) _ DATA (32-bit hex, 8 chars) _ CYCLE (decimal)
  // Example: 00000000_0_0_DEADBEEF_0
  // CYCLE: which clock cycle this request should be issued (0 = immediately after reset)
  typedef struct {
    logic [31:0]  addr;
    logic         write;
    logic [1:0]   l1_id;
    logic [31:0]  data;   // 32-bit word data
    int           cycle;  // Clock cycle when to issue this request
  } test_vector_t;

  // Test stimulus
  initial begin
    string test_file_path;

    string filename;
    int test_file;
    string line;
    test_vector_t tv;
    int vector_count;
    test_vector_t all_vectors[$];  // Dynamic queue
    test_vector_t vectors_by_cycle[][$];
    int max_cycle;

    /** Uncomment the specific test you want to run. **/
    // test_file_path = "../tests/test1.single_read.txt";
    // test_file_path = "../tests/test2.single_write.txt";
    // test_file_path = "../tests/test3.coherence.txt";
    // test_file_path = "../tests/test4.arbitration.txt";
    test_file_path = "../tests/test5.eviction.txt";
    vector_count = 0;
    max_cycle = 0;

    $display("\n=== Data-Driven Cache Coherence Testbench ===\n");
    $display("Loading test: %s\n", test_file_path);

    for (int l1 = 0; l1 < 4; l1++) begin
      dut.l1_valid[l1] = 1'b0;
      dut.l1_mem_write[l1] = 1'b0;
      dut.l1_data_adr[l1] = 32'h0;
      dut.l1_write_data[l1] = 32'h0;
    end

    reset = 1'b1;
    repeat (2) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);
    sim_cycle = 0;

    // Load the specified test file
    $display("[TEST] Loading %s", test_file_path);
    test_file = $fopen(test_file_path, "r");

    if (test_file == 0) begin
      $display("  ERROR: Could not open file %s\n", test_file_path);
      $stop;
    end

    // Load all vectors from this test file
    while ($fgets(line, test_file)) begin
      // Skip empty lines and comments
      if (line == "" || line[0] == "/") continue;

      // Parse test vector with cycle field
      if (parse_test_vector(line, tv)) begin
        all_vectors.push_back(tv);
        if (tv.cycle > max_cycle) max_cycle = tv.cycle;
      end
    end
    $fclose(test_file);

    vectors_by_cycle = new[max_cycle + 1];
    foreach (all_vectors[i]) begin
      if (all_vectors[i].cycle >= 0 && all_vectors[i].cycle <= max_cycle) begin
        vectors_by_cycle[all_vectors[i].cycle].push_back(all_vectors[i]);
      end
    end

    $display("  Loaded %0d vectors (cycles 0-%0d)\n", all_vectors.size(), max_cycle);

    // Execute vectors grouped by cycle (enables concurrent requests)
    vector_count = 0;
    for (int cycle = 0; cycle <= max_cycle; cycle++) begin
      // Find all vectors to issue at this cycle (bucketed, no re-issue)
      test_vector_t pending_vectors[$];
      pending_vectors = vectors_by_cycle[cycle];

      // Issue all pending requests concurrently
      if (pending_vectors.size() > 0) begin
        // Default all request valids low; we will pulse only selected requesters
        for (int l1 = 0; l1 < 4; l1++) begin
          dut.l1_valid[l1] = 1'b0;
        end

        $display("  [Cycle %0d] Issuing %0d request(s):", cycle, pending_vectors.size());
        foreach (pending_vectors[i]) begin
          string op_name;
          op_name = pending_vectors[i].write ? "WRITE" : "READ";
          $display("    L1-%0d %s @ 0x%h", pending_vectors[i].l1_id, op_name, pending_vectors[i].addr);
          issue_request(pending_vectors[i]);
        end

        // Wait for all pending requests to complete
        wait_for_all_ready(pending_vectors, max_cycle, cycle);
        
        // Display results
        foreach (pending_vectors[i]) begin
          if (pending_vectors[i].write) begin
            $display("      L1-%0d Write OK (data: 0x%h)", pending_vectors[i].l1_id, pending_vectors[i].data);
          end else begin
            $display("      L1-%0d Read data: 0x%h", pending_vectors[i].l1_id, dut.l1_read_data[pending_vectors[i].l1_id]);
          end
        end
        
        vector_count += pending_vectors.size();
        repeat (2) @(posedge clk);
      end
    end

    $display("\n  Completed %0d vectors\n", vector_count);
    $display("=== Test Complete ===\n");
    $stop;
  end

  // Bus monitor (BusRdX only)
  always @(posedge clk) begin
    if (dut.bus_op === 3'b001) begin
      $display("[BusRdX @ cycle %0d] Adr=0x%h Shared=%b Valid=%b Data=%h Req=%b Grant=%b",
               sim_cycle, dut.bus_addr, dut.bus_shared, dut.bus_valid, dut.bus_data,
               dut.l1_bus_req, dut.l1_bus_grant);
    end
  end

  // Parse test vector from string
  function automatic bit parse_test_vector(string line, output test_vector_t tv);
    string parts[5];  // Now 5 parts: addr, write, l1_id, data, cycle
    int str_pos = 0;
    int part_idx = 0;
    string current_part = "";

    // Split by underscore
    for (int i = 0; i < line.len(); i = i + 1) begin
      if (line[i] == "_") begin
        parts[part_idx] = current_part;
        current_part = "";
        part_idx = part_idx + 1;
        if (part_idx > 4) return 1'b0; // Too many parts
      end else if (line[i] != "\n" && line[i] != "\r" && line[i] != " ") begin
        current_part = {current_part, line[i]};
      end
    end
    parts[part_idx] = current_part; // Last part

    if (part_idx < 3) return 1'b0; // At least 4 parts required (addr, write, l1_id, data)
    if (part_idx < 4) return 1'b0; // Actually need all 5

    // Parse each field
    tv.addr = string_to_hex32(parts[0]);
    tv.write = (parts[1] == "1") ? 1'b1 : 1'b0;
    tv.l1_id = string_to_int(parts[2]);
    tv.data = string_to_hex32(parts[3]);  // 32-bit word data
    tv.cycle = string_to_int(parts[4]);   // Cycle when to issue request

    return 1'b1;
  endfunction

  // Helper: Convert hex string to 32-bit value
  function automatic logic [31:0] string_to_hex32(string s);
    logic [31:0] result = 32'h0;
    for (int i = 0; i < s.len(); i = i + 1) begin
      logic [3:0] nibble = 4'h0;
      if (s[i] >= "0" && s[i] <= "9") nibble = s[i] - "0";
      else if (s[i] >= "a" && s[i] <= "f") nibble = s[i] - "a" + 10;
      else if (s[i] >= "A" && s[i] <= "F") nibble = s[i] - "A" + 10;
      result = (result << 4) | nibble;
    end
    return result;
  endfunction

  // Helper: Convert hex string to 128-bit value
  function automatic logic [127:0] string_to_hex128(string s);
    logic [127:0] result = 128'h0;
    for (int i = 0; i < s.len(); i = i + 1) begin
      logic [3:0] nibble = 4'h0;
      if (s[i] >= "0" && s[i] <= "9") nibble = s[i] - "0";
      else if (s[i] >= "a" && s[i] <= "f") nibble = s[i] - "a" + 10;
      else if (s[i] >= "A" && s[i] <= "F") nibble = s[i] - "A" + 10;
      result = (result << 4) | nibble;
    end
    return result;
  endfunction

  // Helper: Convert string to int
  function automatic int string_to_int(string s);
    int result = 0;
    for (int i = 0; i < s.len(); i = i + 1) begin
      if (s[i] >= "0" && s[i] <= "9") begin
        result = result * 10 + (s[i] - "0");
      end
    end
    return result;
  endfunction

  // Issue a single request (non-blocking)
  task automatic issue_request(test_vector_t tv);
    dut.l1_valid[tv.l1_id] = 1'b1;
    dut.l1_mem_write[tv.l1_id] = tv.write;
    dut.l1_data_adr[tv.l1_id] = tv.addr;  // Byte-addressed (RISC-V convention)
    dut.l1_write_data[tv.l1_id] = tv.data;  // 32-bit word
  endtask

  // Wait for a single L1 to become ready
  task automatic wait_for_ready_single(input int l1_id, input int max_cycles);
    int cycles = 0;
    while (~dut.l1_ready[l1_id] && cycles < max_cycles) begin
      @(posedge clk);
      cycles = cycles + 1;
    end
    if (cycles >= max_cycles) begin
      $display("        ERROR: L1-%0d timeout after %0d cycles", l1_id, max_cycles);
    end
  endtask

  // Wait for all pending L1s to become ready (concurrent wait)
  task automatic wait_for_all_ready(ref test_vector_t pending_vectors[$], input int max_cycle, input int current_cycle);
    int done_count = 0;
    int total_count = pending_vectors.size();
    int cycles = 0;
    int max_wait_cycles = 50;  // Generous timeout
    bit ready_mask[];

    ready_mask = new[total_count];
    for (int i = 0; i < total_count; i++) ready_mask[i] = 1'b0;

    @(posedge clk);  // At least one clock cycle after issuing

    // Keep waiting until all L1s report ready and we've dropped Valid
    while (done_count < total_count && cycles < max_wait_cycles) begin
      done_count = 0;
      foreach (pending_vectors[i]) begin
        if (!ready_mask[i] && dut.l1_ready[pending_vectors[i].l1_id]) begin
          // Mark this request as done and drop Valid for THIS specific L1
          ready_mask[i] = 1'b1;
          dut.l1_valid[pending_vectors[i].l1_id] = 1'b0;
        end
        if (ready_mask[i]) begin
          done_count++;
        end
      end
      
      if (done_count < total_count) begin
        @(posedge clk);
        cycles++;
      end
    end

    if (done_count < total_count) begin
      $display("        ERROR: Not all L1s ready after %0d cycles", max_wait_cycles);
      $display("        [BUS] op=%b adr=0x%h shared=%b valid=%b data=%h", 
               dut.bus_op, dut.bus_addr, dut.bus_shared, dut.bus_valid, dut.bus_data);
      foreach (pending_vectors[i]) begin
        if (!ready_mask[i]) begin
          $display("          L1-%0d (addr 0x%08x) still not ready", pending_vectors[i].l1_id, pending_vectors[i].addr);
        end
      end
    end
  endtask

  // Apply test vector (old method - kept for reference, now unused)
  task automatic apply_test(test_vector_t tv, int test_num, int vec_num);
    string op_name = tv.write ? "WRITE" : "READ";
    $display("    [Vector %0d] L1-%0d %s @ 0x%h", vec_num, tv.l1_id, op_name, tv.addr);

    dut.l1_valid[tv.l1_id] = 1'b1;
    dut.l1_mem_write[tv.l1_id] = tv.write;
    dut.l1_data_adr[tv.l1_id] = tv.addr;  // Byte-addressed (RISC-V convention)
    dut.l1_write_data[tv.l1_id] = tv.data;  // 32-bit word

    @(posedge clk);
    wait_for_ready_single(tv.l1_id, 30);
    dut.l1_valid[tv.l1_id] = 1'b0;

    if (tv.write) begin
      $display("      -> Write OK (data: 0x%h)", tv.data);
    end else begin
      $display("      -> Read data: 0x%h", dut.l1_read_data[tv.l1_id]);
    end

    repeat (1) @(posedge clk);
  endtask

  // Helper task: Wait for L1 ready signal (legacy, kept for compatibility)
  task automatic wait_for_ready(input int l1_id, input int max_cycles);
    int cycles = 0;
    while (~dut.l1_ready[l1_id] && cycles < max_cycles) begin
      @(posedge clk);
      cycles = cycles + 1;
    end
    if (cycles >= max_cycles) begin
      $display("      ERROR: L1-%0d timeout after %0d cycles", l1_id, max_cycles);
    end
  endtask

endmodule
