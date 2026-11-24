// 逐拍时序追踪: taxi_axi_ram 一笔 4 拍写突发 + 一笔 4 拍读突发
// 激励全部在 negedge 驱动; 握手用"边沿计数器"检测, 无竞争
`timescale 1ns / 1ps
`default_nettype none

module tb_axi_ram_trace();

logic clk = 1'b0;
logic rst = 1'b1;
always #5 clk = ~clk;

taxi_axi_if #(.DATA_W(32), .ADDR_W(16), .STRB_W(4), .ID_W(4)) s_axi();

taxi_axi_ram #(.ADDR_W(16), .PIPELINE_OUTPUT(1'b0)) uut (
    .clk(clk), .rst(rst), .s_axi_wr(s_axi), .s_axi_rd(s_axi)
);

integer cyc = 0;
integer aw_hs = 0, w_hs = 0, ar_hs = 0;

// 握手计数器: 在 posedge 采样 valid&ready (读的是边沿前的值)
always @(posedge clk) begin
    if (s_axi.awvalid && s_axi.awready) aw_hs = aw_hs + 1;
    if (s_axi.wvalid  && s_axi.wready ) w_hs  = w_hs  + 1;
    if (s_axi.arvalid && s_axi.arready) ar_hs = ar_hs + 1;
end

task automatic wr_aw(input [15:0] a, input [7:0] len);
    int n;
    n = aw_hs;
    s_axi.awaddr <= a; s_axi.awlen <= len; s_axi.awvalid <= 1'b1;
    while (aw_hs == n) @(negedge clk);
    s_axi.awvalid <= 1'b0;
endtask

task automatic wr_beat(input [31:0] d, input last);
    int n;
    n = w_hs;
    s_axi.wdata <= d; s_axi.wstrb <= 4'hF; s_axi.wlast <= last; s_axi.wvalid <= 1'b1;
    while (w_hs == n) @(negedge clk);
    s_axi.wvalid <= 1'b0; s_axi.wlast <= 1'b0;
endtask

task automatic rd_ar(input [15:0] a, input [7:0] len);
    int n;
    n = ar_hs;
    s_axi.araddr <= a; s_axi.arlen <= len; s_axi.arvalid <= 1'b1;
    while (ar_hs == n) @(negedge clk);
    s_axi.arvalid <= 1'b0;
endtask

initial begin
    s_axi.awid = '0; s_axi.awaddr = '0; s_axi.awlen = '0; s_axi.awsize = 3'd2;
    s_axi.awburst = 2'b01; s_axi.awlock = 1'b0; s_axi.awcache = 4'b0011;
    s_axi.awprot = 3'b000; s_axi.awqos = 4'd0; s_axi.awregion = 4'd0;
    s_axi.awuser = '0; s_axi.awvalid = 1'b0;
    s_axi.wdata = '0; s_axi.wstrb = 4'hF; s_axi.wlast = 1'b0; s_axi.wuser = '0;
    s_axi.wvalid = 1'b0;
    s_axi.bready = 1'b1;
    s_axi.arid = '0; s_axi.araddr = '0; s_axi.arlen = '0; s_axi.arsize = 3'd2;
    s_axi.arburst = 2'b01; s_axi.arlock = 1'b0; s_axi.arcache = 4'b0011;
    s_axi.arprot = 3'b000; s_axi.arqos = 4'd0; s_axi.arregion = 4'd0;
    s_axi.aruser = '0; s_axi.arvalid = 1'b0;
    s_axi.rready = 1'b1;

    repeat (3) @(negedge clk);
    rst <= 1'b0;

    wr_aw(16'h0010, 8'd3);
    wr_beat(32'h1111_1111, 1'b0);
    wr_beat(32'h2222_2222, 1'b0);
    wr_beat(32'h3333_3333, 1'b0);
    wr_beat(32'h4444_4444, 1'b1);
    repeat (2) @(negedge clk);

    rd_ar(16'h0010, 8'd3);
    repeat (10) @(negedge clk);
    $display("DONE");
    $finish;
end

initial begin
    #100000;
    $display("TIMEOUT");
    $finish;
end

always @(negedge clk) begin
    cyc <= cyc + 1;
    $display("E%0d t=%0t|AW v%b r%b|W v%b r%b l%b d%h|B v%b r%b|AR v%b r%b|R v%b r%b l%b d%h|wst%0d rst%0d mem4=%h",
        cyc, $time,
        s_axi.awvalid, s_axi.awready,
        s_axi.wvalid, s_axi.wready, s_axi.wlast, s_axi.wdata,
        s_axi.bvalid, s_axi.bready,
        s_axi.arvalid, s_axi.arready,
        s_axi.rvalid, s_axi.rready, s_axi.rlast, s_axi.rdata,
        uut.write_state_reg, uut.read_state_reg,
        uut.mem[4]);
end

endmodule
`default_nettype wire
