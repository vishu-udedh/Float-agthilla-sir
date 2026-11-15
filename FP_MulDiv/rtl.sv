
module fp_muldiv (
    input  logic        clk,
    input  logic        reset,
    input  logic        in_valid,
    input  logic        div,
    input  logic [31:0] a,
    input  logic [31:0] b,

    output logic        out_valid,
    output logic [31:0] result
);

    // Input registers
    logic [31:0] a_reg, b_reg;
    logic div_reg;
    logic pending;

    // Unpacked operand A
    logic sign_a;
    logic [7:0] exponent_a;
    logic [22:0] fraction_a;
    logic [23:0] significand_a;
    logic signed [9:0] unbiased_exp_a;
    logic a_zero, a_subnormal, a_infinity, a_nan;

    // Unpacked operand B
    logic sign_b;
    logic [7:0] exponent_b;
    logic [22:0] fraction_b;
    logic [23:0] significand_b;
    logic signed [9:0] unbiased_exp_b;
    logic b_zero, b_subnormal, b_infinity, b_nan;

    // Special-case outputs
    logic special_valid;
    logic [31:0] special_result;

    // Multiplication datapath
    logic [47:0] product;
    logic signed [10:0] mul_exponent;
    logic mul_sign;
    logic [31:0] mul_result;

    // Division datapath
    logic [63:0] quotient;
    logic [23:0] remainder;
    logic signed [10:0] div_exponent;
    logic div_sign;
    logic [31:0] div_result;

    logic [31:0] calculated_result;

    // Unpack operand A
    fp_unpack unpack_a (
        .fp_in(a_reg),
        .sign(sign_a),
        .exponent(exponent_a),
        .fraction(fraction_a),
        .significand(significand_a),
        .unbiased_exp(unbiased_exp_a),
        .is_zero(a_zero),
        .is_subnormal(a_subnormal),
        .is_infinity(a_infinity),
        .is_nan(a_nan)
    );

    // Unpack operand B
    fp_unpack unpack_b (
        .fp_in(b_reg),
        .sign(sign_b),
        .exponent(exponent_b),
        .fraction(fraction_b),
        .significand(significand_b),
        .unbiased_exp(unbiased_exp_b),
        .is_zero(b_zero),
        .is_subnormal(b_subnormal),
        .is_infinity(b_infinity),
        .is_nan(b_nan)
    );

    // Detect special cases
    fp_special_cases special_unit (
        .a(a_reg),
        .b(b_reg),
        .div(div_reg),
        .special_valid(special_valid),
        .special_result(special_result)
    );

    // Multiplication
    fp_multiply multiply_unit (
        .significand_a(significand_a),
        .significand_b(significand_b),
        .exponent_a(unbiased_exp_a),
        .exponent_b(unbiased_exp_b),
        .sign_a(sign_a),
        .sign_b(sign_b),
        .product(product),
        .result_exponent(mul_exponent),
        .result_sign(mul_sign)
    );

    fp_mul_normalize mul_normalize_unit (
        .product(product),
        .exponent_sum(mul_exponent),
        .sign(mul_sign),
        .result(mul_result)
    );

    // Division
    fp_divide divide_unit (
        .significand_a(significand_a),
        .significand_b(significand_b),
        .exponent_a(unbiased_exp_a),
        .exponent_b(unbiased_exp_b),
        .sign_a(sign_a),
        .sign_b(sign_b),
        .quotient(quotient),
        .remainder(remainder),
        .exponent_difference(div_exponent),
        .result_sign(div_sign)
    );

    fp_div_normalize div_normalize_unit (
        .quotient(quotient),
        .remainder(remainder),
        .exponent_difference(div_exponent),
        .sign(div_sign),
        .result(div_result)
    );

    // Select the appropriate result
    always_comb begin
        if (special_valid)
            calculated_result = special_result;
        else if (div_reg)
            calculated_result = div_result;
        else
            calculated_result = mul_result;
    end

    // Input capture and output handshake
    always_ff @(posedge clk) begin
        if (reset) begin
            a_reg     <= 32'b0;
            b_reg     <= 32'b0;
            div_reg   <= 1'b0;
            pending   <= 1'b0;
            out_valid <= 1'b0;
            result    <= 32'b0;
        end
        else begin
            out_valid <= pending;

            if (pending)
                result <= calculated_result;

            pending <= in_valid;

            if (in_valid) begin
                a_reg   <= a;
                b_reg   <= b;
                div_reg <= div;
            end
        end
    end

endmodule
