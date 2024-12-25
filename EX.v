`include "lib/defines.vh"

module EX(
    input wire clk,                        // 时钟信号
    input wire rst,                        // 复位信号
    input wire [StallBus-1:0] stall,      // 来自其他模块的停顿信号
    input wire [ID_TO_EX_WD-1:0] id_to_ex_bus, // 从ID阶段传来的总线数据

    output wire [EX_TO_MEM_WD-1:0] ex_to_mem_bus,  // 传递给MEM阶段的总线
    output wire data_sram_en,              // 数据SRAM使能信号
    output wire [3:0] data_sram_wen,       // 数据SRAM写使能信号
    output wire [31:0] data_sram_addr,     // 数据SRAM的地址信号
    output wire [37:0] ex_to_id,           // EX阶段的输出信息传递给ID阶段
    output wire [31:0] data_sram_wdata,    // 数据SRAM写入的数据
    output wire stallreq_from_ex,          // EX阶段的停顿请求信号
    output wire ex_is_load,                // 判断是否为加载指令（LW）
    output wire [65:0] hilo_ex_to_id       // hi/lo寄存器的状态传递
);

    // 寄存器，用于存储从ID阶段传来的数据
    reg [ID_TO_EX_WD-1:0] id_to_ex_bus_r;

    // 时钟上升沿时更新id_to_ex_bus_r寄存器
    always @ (posedge clk) begin
        if (rst) begin
            id_to_ex_bus_r <= ID_TO_EX_WD'b0;  // 复位时清空寄存器
        end
        else if (stall[2]==Stop && stall[3]==NoStop) begin
            id_to_ex_bus_r <= ID_TO_EX_WD'b0;  // 如果处于停顿状态，清空寄存器
        end
        else if (stall[2]==NoStop) begin
            id_to_ex_bus_r <= id_to_ex_bus;  // 如果没有停顿，更新寄存器
        end
    end

    // 从id_to_ex_bus寄存器提取不同的信号
    wire [31:0] ex_pc, inst;
    wire [11:0] alu_op;                // ALU操作类型
    wire [2:0] sel_alu_src1;           // ALU源操作数1的选择
    wire [3:0] sel_alu_src2;           // ALU源操作数2的选择
    wire data_ram_en;                  // 数据内存使能信号
    wire [3:0] data_ram_wen, data_ram_readen; // 数据内存写使能和读使能信号
    wire rf_we;                        // 寄存器文件写使能
    wire [4:0] rf_waddr;               // 寄存器文件写地址
    wire sel_rf_res;                   // 寄存器结果选择信号
    wire [31:0] rf_rdata1, rf_rdata2;  // 从寄存器文件读取的数据
    reg is_in_delayslot;               // 是否处于延迟槽

    // 解析从ID到EX阶段传递的总线信号
    assign {
        data_ram_readen,  // 数据读取使能
        inst_mthi,        // mthi指令标识
        inst_mtlo,        // mtlo指令标识
        inst_multu,       // multu指令标识
        inst_mult,        // mult指令标识
        inst_divu,        // divu指令标识
        inst_div,         // div指令标识
        ex_pc,            // 当前指令地址
        inst,             // 当前指令
        alu_op,           // ALU操作类型
        sel_alu_src1,     // ALU操作数1选择
        sel_alu_src2,     // ALU操作数2选择
        data_ram_en,      // 数据内存使能信号
        data_ram_wen,     // 数据内存写使能信号
        rf_we,            // 寄存器写使能信号
        rf_waddr,         // 寄存器写地址
        sel_rf_res,       // 寄存器结果选择
        rf_rdata1,        // 寄存器1的读取数据
        rf_rdata2         // 寄存器2的读取数据
    } = id_to_ex_bus_r;

    // 判断是否为加载指令（LW），即指令的操作码是否为 `6'b100011`
    assign ex_is_load = (inst[31:26] == 6'b10_0011) ? 1'b1 : 1'b0;

    // 立即数扩展，符号扩展、零扩展和位移扩展
    wire [31:0] imm_sign_extend, imm_zero_extend, sa_zero_extend;
    assign imm_sign_extend = {{16{inst[15]}}, inst[15:0]};  // 符号扩展
    assign imm_zero_extend = {16'b0, inst[15:0]};            // 零扩展
    assign sa_zero_extend = {27'b0, inst[10:6]};             // 位移扩展

    // ALU操作数选择逻辑
    wire [31:0] alu_src1, alu_src2;
    wire [31:0] alu_result, ex_result;

    // ALU源操作数1选择逻辑
    assign alu_src1 = sel_alu_src1[1] ? ex_pc :      // 如果选择了PC作为源操作数
                      sel_alu_src1[2] ? sa_zero_extend : rf_rdata1;  // 否则选择移位扩展或寄存器数据

    // ALU源操作数2选择逻辑
    assign alu_src2 = sel_alu_src2[1] ? imm_sign_extend :   // 如果选择了符号扩展立即数
                      sel_alu_src2[2] ? 32'd8 :              // 如果选择了常数8
                      sel_alu_src2[3] ? imm_zero_extend : rf_rdata2; // 否则选择零扩展立即数或寄存器数据

    // ALU运算模块
    alu u_alu(
        .alu_control(alu_op),  // ALU操作类型
        .alu_src1(alu_src1),   // ALU源操作数1
        .alu_src2(alu_src2),   // ALU源操作数2
        .alu_result(alu_result)  // ALU计算结果
    );

    assign ex_result = alu_result;  // EX阶段计算的结果

    // 将EX阶段的结果和其他信号打包传递到MEM阶段
    assign ex_to_mem_bus = {
        data_ram_readen,  // 数据读取使能
        ex_pc,            // 指令地址
        data_ram_en,      // 数据内存使能
        data_ram_wen,     // 数据内存写使能
        sel_rf_res,       // 寄存器结果选择
        rf_we,            // 寄存器写使能
        rf_waddr,         // 寄存器写地址
        ex_result         // EX阶段计算结果
    };

    // EX阶段的状态信息传递到ID阶段
    assign ex_to_id = {
        rf_we,        // 寄存器写使能
        rf_waddr,     // 寄存器写地址
        ex_result     // EX阶段结果
    };

    // 数据内存相关信号传递
    assign data_sram_en = data_ram_en;
    assign data_sram_wen =   (data_ram_readen == 4'b0101 && ex_result[1:0] == 2'b00) ? 4'b0001
                            :(data_ram_readen == 4'b0101 && ex_result[1:0] == 2'b01) ? 4'b0010
                            :(data_ram_readen == 4'b0101 && ex_result[1:0] == 2'b10) ? 4'b0100
                            :(data_ram_readen == 4'b0101 && ex_result[1:0] == 2'b11) ? 4'b1000
                            :(data_ram_readen == 4'b0111 && ex_result[1:0] == 2'b00) ? 4'b0011
                            :(data_ram_readen == 4'b0111 && ex_result[1:0] == 2'b10) ? 4'b1100
                            : data_ram_wen;  // 写使能信号

    // 数据内存地址
    assign data_sram_addr = ex_result;

    // 数据内存写入数据
    assign data_sram_wdata = data_sram_wen == 4'b1111 ? rf_rdata2
                            : data_sram_wen == 4'b0001 ? {24'b0, rf_rdata2[7:0]}
                            : data_sram_wen == 4'b0010 ? {16'b0, rf_rdata2[7:0], 8'b0}
                            : data_sram_wen == 4'b0100 ? {8'b0, rf_rdata2[7:0], 16'b0}
                            : data_sram_wen == 4'b1000 ? {rf_rdata2[7:0], 24'b0}
                            : data_sram_wen == 4'b0011 ? {16'b0, rf_rdata2[15:0]}
                            : data_sram_wen == 4'b1100 ? {rf_rdata2[15:0], 16'b0}
                            : 32'b0;  // 根据写使能确定写入的数据

    // 处理hi和lo寄存器的写操作
    wire hi_wen, lo_wen, inst_mthi, inst_mtlo;
    wire [31:0] hi_data, lo_data;

    assign hi_wen = inst_divu | inst_div | inst_mult | inst_multu | inst_mthi;  // 判断是否写hi寄存器
    assign lo_wen = inst_divu | inst_div | inst_mult | inst_multu | inst_mtlo;  // 判断是否写lo寄存器

    // 计算hi寄存器的数据
    assign hi_data = (inst_div | inst_divu) ? div_result[63:32]   // 余数
                    : (inst_mult | inst_multu) ? mul_result[63:32]  // 乘法结果高32位
                    : (inst_mthi) ? rf_rdata1 : 32'b0;  // mthi指令

    // 计算lo寄存器的数据
    assign lo_data = (inst_div | inst_divu) ? div_result[31:0]   // 商
                    : (inst_mult | inst_multu) ? mul_result[31:0]  // 乘法结果低32位
                    : (inst_mtlo) ? rf_rdata1 : 32'b0;  // mtlo指令

    // 将hi和lo的状态传递到ID阶段
    assign hilo_ex_to_id = {
        hi_wen,         // hi寄存器写使能
        lo_wen,         // lo寄存器写使能
        hi_data,        // hi寄存器数据
        lo_data         // lo寄存器数据
    };

    // MUL部分
    wire inst_mult, inst_multu;
    wire [63:0] mul_result;  // 乘法结果

    // 调用自定义的乘法除法模块
    custom_mul_div u_mul_div(
        .rst(rst),
        .clk(clk),
        .op1(rf_rdata1),
        .op2(rf_rdata2),
        .start_mul(inst_mult | inst_multu),
        .start_div(inst_div | inst_divu),
        .mul_result(mul_result),
        .div_result(div_result),
        .mul_ready(mul_ready),
        .div_ready(div_ready)
    );

endmodule

// 自定义乘法除法模块
module custom_mul_div (
    input               rst,            // 复位信号
    input               clk,            // 时钟信号
    input [31:0]        op1,            // 操作数1
    input [31:0]        op2,            // 操作数2
    input               start_mul,      // 启动乘法标志
    input               start_div,      // 启动除法标志
    output reg [63:0]   mul_result,     // 乘法结果 64位
    output reg [31:0]   div_result,     // 除法结果 32位
    output reg          mul_ready,      // 乘法结果准备标志
    output reg          div_ready       // 除法结果准备标志
);
    reg [31:0] dividend, divisor;
    reg [63:0] temp_mul_result;        // 临时乘法结果
    reg [31:0] quotient, remainder;    // 除法的商和余数
    integer i;

    // 乘法部分：递归乘法
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mul_ready <= 0;
            temp_mul_result <= 0;
        end else if (start_mul) begin
            temp_mul_result <= 0;
            for (i = 0; i < 32; i = i + 1) begin
                if (op2[i]) begin
                    temp_mul_result = temp_mul_result + (op1 << i);
                end
            end
            mul_result <= temp_mul_result;
            mul_ready <= 1;
        end
    end

    // 除法部分：恢复除法算法
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            div_ready <= 0;
            quotient <= 0;
            remainder <= 0;
        end else if (start_div) begin
            dividend <= op1;
            divisor <= op2;
            quotient <= 0;
            remainder <= dividend;
            for (i = 31; i >= 0; i = i - 1) begin
                remainder = remainder << 1;
                remainder[0] <= dividend[31];  // 将最左边的位移入余数
                dividend = dividend << 1;      // 被除数左移
                if (remainder >= divisor) begin
                    remainder = remainder - divisor;
                    quotient[i] <= 1;
                end
            end
            div_result <= quotient;
            div_ready <= 1;
        end
    end
endmodule




