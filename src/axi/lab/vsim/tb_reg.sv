// 三种 register type 的吞吐对比: 源侧连发 8 笔 AW, 数发完所需周期
// 用法:
//   编译 REG0 变体: awready 恒 1
//   编译 REG2 -DPATTERN 变体: awready 走 101 图案
`timescale 1ns / 1ps
`default_nettype none

module tb_reg();

logic clk = 1'b0;
logic rst = 1'b1;
always #5 clk = ~clk;

`ifdef REG0
localparam int REG_TYPE = 0;
localparam string REG_NAME = "0-bypass";
`elsif REG1
localparam int REG_TYPE = 1;
localparam string REG_NAME = "1-simple";
`else
localparam int REG_TYPE = 2;
localparam string REG_NAME = "2-skid";
`endif

localparam int N_TX = 8;

taxi_axi_if #(.DATA_W(32), .ADDR_W(32), .STRB_W(4), .ID_W(4)) s_axi();
taxi_axi_if #(.DATA_W(32), .ADDR_W(32), .STRB_W(4), .ID_W(4)) m_axi();

taxi_axi_register_wr #(
    .AW_REG_TYPE(REG_TYPE),
    .W_REG_TYPE(REG_TYPE),
    .B_REG_TYPE(REG_TYPE)
) uut (
    .clk(clk), .rst(rst),
    .s_axi_wr(s_axi),
    .m_axi_wr(m_axi)
);

// 下游 ready 源
`ifdef PATTERN
// 每拍变化的三位图案 101, 让上游无法靠"猜"提前准备
logic [2:0] pat = 3'b101;
always @(posedge clk) pat <= {pat[1:0], pat[2]};
assign m_axi.awready = pat[0];
`else
assign m_axi.awready = 1'b1;
`endif

assign m_axi.wready = 1'b1;
assign m_axi.bvalid = 1'b1;
assign m_axi.bid    = 4'h0;
assign m_axi.bresp  = 2'b00;

integer cyc = 0;
integer aw_hs = 0;
integer first_hs_cyc = -1;
always @(posedge clk) begin
    cyc = cyc + 1;
    if (s_axi.awvalid && s_axi.awready) begin
        aw_hs = aw_hs + 1;
        if (first_hs_cyc < 0) first_hs_cyc = cyc;
    end
end

initial begin
    s_axi.awid = 4'h1; s_axi.awaddr = 32'h1000; s_axi.awlen = 8'd0; s_axi.awsize = 3'd2;
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
    @(negedge clk);

    // 连发 N_TX 笔: 每拍抱着 awvalid 不放, 直到握手计数增加
    for (int i = 0; i < N_TX; i++) begin
        int n;
        n = aw_hs;
        s_axi.awaddr <= 32'h1000 + i * 4;
        s_axi.awvalid <= 1'b1;
        while (aw_hs == n) @(negedge clk);
    end
    s_axi.awvalid <= 1'b0;

`ifdef PATTERN
    $display("RESULT reg_type=%s accepted=%0d at cycle=%0d (sink awready = 101 pattern, rotating)", REG_NAME, N_TX, cyc);
`else
    $display("RESULT reg_type=%s accepted=%0d at cycle=%0d (sink awready = constant 1)", REG_NAME, N_TX, cyc);
`endif
    $finish;
end

initial begin
    #100000; $display("TIMEOUT"); $finish;
end

endmodule
`default_nettype wire
