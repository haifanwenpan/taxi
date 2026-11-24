// crossbar 地址解码 + 准入 + DECERR 演示
`timescale 1ns / 1ps
`default_nettype none
`define VSIM_WORKAROUND

module tb_crossbar_addr();

logic clk = 1'b0;
logic rst = 1'b1;
always #5 clk = ~clk;

localparam S_COUNT = 2;
localparam M_COUNT = 2;

taxi_axi_if #(.DATA_W(32), .ADDR_W(32), .STRB_W(4), .ID_W(6)) s_axi();
taxi_axi_if #(.DATA_W(32), .ADDR_W(32), .STRB_W(4), .ID_W(6)) m_axi[M_COUNT]();

// M0: 0x0000_0000, 16KB (ADDR_W=14); M1: 0x0000_8000, 16KB
taxi_axi_crossbar #(
    .S_COUNT(S_COUNT),
    .M_COUNT(M_COUNT),
    .ADDR_W(32),
    .S_THREADS({2{32'd2}}),
    .S_ACCEPT({2{32'd4}}),
    .M_ADDR_W({14, 14}),
    .M_ISSUE({32'd2, 32'd2})
) uut (
    .clk(clk), .rst(rst),
    .s_axi_wr(s_axi), .s_axi_rd(s_axi),
    .m_axi_wr(m_axi), .m_axi_rd(m_axi)
);

// 两个下游从机: 永远 1 拍内 OKAY 响应
for (genvar i = 0; i < M_COUNT; i++) begin : slaves
    assign m_axi[i].awready = 1'b1;
    assign m_axi[i].wready  = 1'b1;
    assign m_axi[i].bvalid  = 1'b1;
    assign m_axi[i].bresp   = 2'b00;
    assign m_axi[i].arready = 1'b1;
    assign m_axi[i].rvalid  = 1'b1;
    assign m_axi[i].rdata   = 32'hC0DE_0000 + i;
    assign m_axi[i].rresp   = 2'b00;
    assign m_axi[i].rlast   = 1'b1;
end

integer aw_hs = 0, ar_hs = 0, b_hs = 0, r_hs = 0;
always @(posedge clk) begin
    if (s_axi.awvalid && s_axi.awready) aw_hs = aw_hs + 1;
    if (s_axi.arvalid && s_axi.arready) ar_hs = ar_hs + 1;
    if (s_axi.bvalid && s_axi.bready) b_hs = b_hs + 1;
    if (s_axi.rvalid && s_axi.rready) r_hs = r_hs + 1;
end

task automatic do_read(input [31:0] a, input [31:0] exp_data);
    int n;
    n = r_hs;
    s_axi.araddr <= a; s_axi.arvalid <= 1'b1;
    while (ar_hs == n) @(negedge clk);
    s_axi.arvalid <= 1'b0;
    while (r_hs == n) @(negedge clk);
    $display("READ  addr=%h -> rdata=%h rresp=%b (expected data %h)", a, s_axi.rdata, s_axi.rresp, exp_data);
endtask

// 监视去往各 master 的握手 (接口数组必须用 genvar 展开索引)
for (genvar g = 0; g < M_COUNT; g++) begin : mon
    always @(posedge clk) begin
        if (m_axi[g].awvalid && m_axi[g].awready)
            $display("       -> M%0d got AW addr=%h id=%h", g, m_axi[g].awaddr, m_axi[g].awid);
        if (m_axi[g].arvalid && m_axi[g].arready)
            $display("       -> M%0d got AR addr=%h id=%h", g, m_axi[g].araddr, m_axi[g].arid);
        if (m_axi[g].bvalid && m_axi[g].bready)
            $display("       <- M%0d B  bid=%h", g, m_axi[g].bid);
        if (m_axi[g].rvalid && m_axi[g].rready)
            $display("       <- M%0d R  rid=%h", g, m_axi[g].rid);
    end
end

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

    do_read(32'h0000_0100, 32'hC0DE_0000);   // 命中 M0
    do_read(32'h0000_8123, 32'hC0DE_0001);   // 命中 M1
    do_read(32'h0000_C000, 32'hXXXX_XXXX);   // 无命中 -> DECERR (rresp=11)

    repeat (4) @(negedge clk);
    $display("DONE");
    $finish;
end

initial begin
    #200000; $display("TIMEOUT"); $finish;
end

endmodule
`default_nettype wire
