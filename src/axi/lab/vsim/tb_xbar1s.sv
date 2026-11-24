// crossbar_1s: 地址解码 / ID 拼接 / DECERR 逐拍演示
`timescale 1ns / 1ps
`default_nettype none

module tb_xbar1s();

logic clk = 1'b0;
logic rst = 1'b1;
always #5 clk = ~clk;

localparam M_COUNT = 2;

taxi_axi_if #(.DATA_W(32), .ADDR_W(32), .STRB_W(4), .ID_W(6)) s_axi();
taxi_axi_if #(.DATA_W(32), .ADDR_W(32), .STRB_W(4), .ID_W(6)) m_axi_wr[M_COUNT]();
taxi_axi_if #(.DATA_W(32), .ADDR_W(32), .STRB_W(4), .ID_W(6)) m_axi_rd[M_COUNT]();

// M0: 基址 0, 宽 14 位(16KB); M1: 基址自动算到 0x4000, 宽 14 位
taxi_axi_crossbar_1s #(
    .M_COUNT(M_COUNT),
    .ADDR_W(32),
    .M_ADDR_W({14, 14}),
    .M_ISSUE({32'd2, 32'd2})
) uut (
    .clk(clk), .rst(rst),
    .s_axi_wr(s_axi), .s_axi_rd(s_axi),
    .m_axi_wr(m_axi_wr), .m_axi_rd(m_axi_rd)
);

// 两个下游从机: 规范响应模型 (收到 AW+W 才回 B, 收到 AR 才回 R)
for (genvar g = 0; g < M_COUNT; g++) begin : slaves
    logic bvalid_q = 1'b0, rvalid_q = 1'b0;
    logic [31:0] rdata_q = '0;
    logic [5:0] rid_q = '0;

    assign m_axi_wr[g].awready = 1'b1;
    assign m_axi_wr[g].wready  = 1'b1;
    assign m_axi_wr[g].bvalid  = bvalid_q;
    assign m_axi_wr[g].bid     = 6'h3F;   // 故意用一个独特的 ID, 便于看 crossbar 是否改写
    assign m_axi_wr[g].bresp   = 2'b00;

    assign m_axi_rd[g].arready = 1'b1;
    assign m_axi_rd[g].rvalid  = rvalid_q;
    assign m_axi_rd[g].rdata   = rdata_q;
    assign m_axi_rd[g].rid     = rid_q;
    assign m_axi_rd[g].rresp   = 2'b00;
    assign m_axi_rd[g].rlast   = 1'b1;

    always @(posedge clk) begin
        if (rst) begin
            bvalid_q <= 1'b0; rvalid_q <= 1'b0;
        end else begin
            if (m_axi_wr[g].wvalid && m_axi_wr[g].wready && m_axi_wr[g].wlast) bvalid_q <= 1'b1;
            if (m_axi_wr[g].bvalid && m_axi_wr[g].bready) bvalid_q <= 1'b0;
            if (m_axi_rd[g].arvalid && m_axi_rd[g].arready) begin
                rvalid_q <= 1'b1; rdata_q <= 32'hC0DE_0000 + g; rid_q <= m_axi_rd[g].arid;
            end
            if (m_axi_rd[g].rvalid && m_axi_rd[g].rready) rvalid_q <= 1'b0;
        end
        if (m_axi_wr[g].awvalid && m_axi_wr[g].awready)
            $display("        -> M%0d AW addr=%h id=%h", g, m_axi_wr[g].awaddr, m_axi_wr[g].awid);
        if (m_axi_wr[g].bvalid && m_axi_wr[g].bready)
            $display("        <- M%0d B  bid=%h", g, m_axi_wr[g].bid);
        if (m_axi_rd[g].arvalid && m_axi_rd[g].arready)
            $display("        -> M%0d AR addr=%h id=%h", g, m_axi_rd[g].araddr, m_axi_rd[g].arid);
        if (m_axi_rd[g].rvalid && m_axi_rd[g].rready)
            $display("        <- M%0d R  rid=%h", g, m_axi_rd[g].rid);
    end
end

integer ar_hs = 0, r_hs = 0, aw_hs = 0, b_hs = 0;
// 在握手那一拍锁存响应值, 否则到 negedge 时 valid 已撤、数据已被下一笔覆盖
logic [5:0]  r_rid_q;  logic [31:0] r_data_q;  logic [1:0] r_resp_q;
logic [5:0]  b_bid_q;  logic [1:0]  b_resp_q;
always @(posedge clk) begin
    if (s_axi.arvalid && s_axi.arready) ar_hs = ar_hs + 1;
    if (s_axi.rvalid  && s_axi.rready ) begin
        r_hs = r_hs + 1;
        r_rid_q = s_axi.rid; r_data_q = s_axi.rdata; r_resp_q = s_axi.rresp;
    end
    if (s_axi.awvalid && s_axi.awready) aw_hs = aw_hs + 1;
    if (s_axi.bvalid  && s_axi.bready ) begin
        b_hs = b_hs + 1;
        b_bid_q = s_axi.bid; b_resp_q = s_axi.bresp;
    end
end

task automatic do_read(input [31:0] a);
    int n;
    n = r_hs;
    s_axi.araddr <= a; s_axi.arid <= 6'h05; s_axi.arvalid <= 1'b1;
    while (ar_hs == n) @(negedge clk);
    s_axi.arvalid <= 1'b0;
    while (r_hs == n) @(negedge clk);
    $display("READ  addr=%h -> rid=%h rdata=%h rresp=%b", a, r_rid_q, r_data_q, r_resp_q);
endtask

task automatic do_write(input [31:0] a);
    int n;
    n = b_hs;
    s_axi.awaddr <= a; s_axi.awid <= 6'h0B; s_axi.awvalid <= 1'b1;
    s_axi.wdata <= 32'hA5A5_0000 + a[15:0]; s_axi.wstrb <= 4'hF; s_axi.wlast <= 1'b1; s_axi.wvalid <= 1'b1;
    while (aw_hs == n) @(negedge clk);
    s_axi.awvalid <= 1'b0;
    while (b_hs == n) @(negedge clk);
    s_axi.wvalid <= 1'b0; s_axi.wlast <= 1'b0;
    $display("WRITE addr=%h -> bid=%h bresp=%b", a, b_bid_q, b_resp_q);
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

    do_read(32'h0000_0100);   // 命中 M0
    do_read(32'h0000_4100);   // 命中 M1 (自动基址 0x4000)
    do_read(32'h0000_C000);   // 无命中 -> DECERR
    do_write(32'h0000_8100);  // 写 M1 域外 -> DECERR

    repeat (4) @(negedge clk);
    $display("DONE");
    $finish;
end

initial begin
    #300000; $display("TIMEOUT"); $finish;
end

integer cyc = 0;
always @(negedge clk) begin
    cyc = cyc + 1;
    $display("C%0d|AR v%b r%b|R v%b r%b l%b resp%b rid%h d%h|AW v%b r%b|B v%b r%b resp%b bid%h|sel%0d decerr%b",
        cyc,
        s_axi.arvalid, s_axi.arready,
        s_axi.rvalid, s_axi.rready, s_axi.rlast, s_axi.rresp, s_axi.rid, s_axi.rdata,
        s_axi.awvalid, s_axi.awready,
        s_axi.bvalid, s_axi.bready, s_axi.bresp, s_axi.bid,
        uut.rd_inst.rd_inst.s_ifaces[0].addr_inst.m_select_reg,
        uut.rd_inst.rd_inst.s_ifaces[0].addr_inst.m_decerr_reg);
end

endmodule
`default_nettype wire
