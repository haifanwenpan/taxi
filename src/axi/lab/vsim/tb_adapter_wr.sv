// taxi_axi_adapter_wr: 32-bit 窄写 -> 128-bit 宽写 的打包波形
// CONVERT_NARROW_BURST=1 时所有突发都重新打包; =0 时只合并整拍宽的突发
`timescale 1ns / 1ps
`default_nettype none

module tb_adapter_wr();

logic clk = 1'b0;
logic rst = 1'b1;
always #5 clk = ~clk;

taxi_axi_if #(.DATA_W(32),  .ADDR_W(32), .STRB_W(4),  .ID_W(4)) s_axi();
taxi_axi_if #(.DATA_W(128), .ADDR_W(32), .STRB_W(16), .ID_W(4)) m_axi();

taxi_axi_adapter_wr #(
    .CONVERT_BURST(1'b1),
    .CONVERT_NARROW_BURST(1'b1)
) uut (
    .clk(clk), .rst(rst),
    .s_axi_wr(s_axi),
    .m_axi_wr(m_axi)
);

// 下游: 永远 ready
assign m_axi.awready = 1'b1;
assign m_axi.wready  = 1'b1;
logic m_bvalid_q = 1'b0;
assign m_axi.bvalid = m_bvalid_q;
assign m_axi.bid    = 4'hA;
assign m_axi.bresp  = 2'b00;
always @(posedge clk) begin
    if (rst) m_bvalid_q <= 1'b0;
    else begin
        if (m_axi.bvalid && m_axi.bready) m_bvalid_q <= 1'b0;
        else if (m_axi.wvalid && m_axi.wready && m_axi.wlast) m_bvalid_q <= 1'b1;
    end
end

integer cyc = 0;
always @(negedge clk) begin
    cyc = cyc + 1;
    $display("C%0d|SAW v%b r%b a%h len%0d sz%0d|SW v%b r%b l%b d%h st%h|B v%b|MAW v%b r%b a%h len%0d sz%0d|MW v%b r%b l%b d%h|",
        cyc,
        s_axi.awvalid, s_axi.awready, s_axi.awaddr, s_axi.awlen, s_axi.awsize,
        s_axi.wvalid, s_axi.wready, s_axi.wlast, s_axi.wdata, s_axi.wstrb,
        s_axi.bvalid,
        m_axi.awvalid, m_axi.awready, m_axi.awaddr, m_axi.awlen, m_axi.awsize,
        m_axi.wvalid, m_axi.wready, m_axi.wlast, m_axi.wdata, m_axi.wstrb);
end

integer aw_hs = 0, w_hs = 0, b_hs = 0;
always @(posedge clk) begin
    if (s_axi.awvalid && s_axi.awready) aw_hs = aw_hs + 1;
    if (s_axi.wvalid  && s_axi.wready ) w_hs  = w_hs  + 1;
    if (s_axi.bvalid  && s_axi.bready ) b_hs  = b_hs  + 1;
end

task automatic put_beat(input [31:0] d);
    int n;
    n = w_hs;
    s_axi.wdata <= d; s_axi.wstrb <= 4'hF; s_axi.wvalid <= 1'b1;
    while (w_hs == n) @(negedge clk);
    s_axi.wvalid <= 1'b0;
endtask

integer n;

initial begin
    s_axi.awid = 4'h3; s_axi.awaddr = 32'h1000; s_axi.awlen = 8'd3; s_axi.awsize = 3'd2;
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

    // 4 拍 32-bit INCR 写, 起始地址 0x1000 (对齐到 128-bit)
    n = aw_hs;
    s_axi.awaddr <= 32'h1000; s_axi.awlen <= 8'd3; s_axi.awsize <= 3'd2;
    s_axi.awvalid <= 1'b1;
    while (aw_hs == n) @(negedge clk);
    s_axi.awvalid <= 1'b0;

    put_beat(32'h1111_1111);
    put_beat(32'h2222_2222);
    put_beat(32'h3333_3333);
    // 最后一拍
    n = w_hs;
    s_axi.wdata <= 32'h4444_4444; s_axi.wstrb <= 4'hF; s_axi.wlast <= 1'b1; s_axi.wvalid <= 1'b1;
    while (w_hs == n) @(negedge clk);
    s_axi.wvalid <= 1'b0; s_axi.wlast <= 1'b0;

    repeat (8) @(negedge clk);
    $display("DONE");
    $finish;
end

initial begin
    #100000; $display("TIMEOUT"); $finish;
end

endmodule
`default_nettype wire
