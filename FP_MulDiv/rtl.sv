module fp_muldiv 
(
  input  logic        clk,
  input  logic        reset,
  input  logic        in_valid,
  input  logic        div,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        out_valid,
  output logic [31:0] result
);

  // FSM states
  localparam logic [1:0] STATE_IDLE   = 2'd0;
  localparam logic [1:0] STATE_DIVIDE = 2'd1;
  localparam logic [1:0] STATE_ROUND  = 2'd2;

  // Restoring-division steps limit
  localparam logic [4:0] LAST_DIVIDE_STEP = 5'd26;

  // Helper: Count leading zeros for 24-bit mantissa
  function automatic [4:0] count_leading_zeros_24(input [23:0] value);
    integer bit_index;
    reg     found_one;
    begin
      count_leading_zeros_24 = 5'd0;
      found_one              = 1'b0;
      for (bit_index = 23; bit_index >= 0; bit_index = bit_index - 1) begin
        if (!found_one && value[bit_index]) begin
          found_one              = 1'b1;
          count_leading_zeros_24 = 5'd23 - bit_index[4:0];
        end
      end
    end
  endfunction

  // 1) Decode inputs
  logic        sign_a, sign_b, sign_result;
  logic [7:0]  exponent_field_a, exponent_field_b;
  logic [22:0] fraction_a, fraction_b;

  logic        a_is_nan, b_is_nan;
  logic        a_is_inf, b_is_inf;
  logic        a_is_zero, b_is_zero;

  logic        result_is_nan;
  logic        result_is_inf;
  logic        result_is_zero;
  logic [31:0] special_case_result; 

  // Normalised 24-bit mantissas
  logic [23:0] mantissa_a_raw, mantissa_b_raw;
  logic [4:0]  leading_zeros_a, leading_zeros_b;
  logic [23:0] mantissa_a, mantissa_b;
  integer      exponent_a, exponent_b;

  always_comb begin
    sign_a           = a[31];
    sign_b           = b[31];
    exponent_field_a = a[30:23];
    exponent_field_b = b[30:23];
    fraction_a       = a[22:0];
    fraction_b       = b[22:0];
    sign_result      = sign_a ^ sign_b;

    a_is_nan  = (exponent_field_a == 8'hFF) && (fraction_a != 23'd0);
    b_is_nan  = (exponent_field_b == 8'hFF) && (fraction_b != 23'd0);
    a_is_inf  = (exponent_field_a == 8'hFF) && (fraction_a == 23'd0);
    b_is_inf  = (exponent_field_b == 8'hFF) && (fraction_b == 23'd0);
    a_is_zero = (exponent_field_a == 8'h00) && (fraction_a == 23'd0);
    b_is_zero = (exponent_field_b == 8'h00) && (fraction_b == 23'd0);

    // Special case handling
    if (div) begin
      result_is_nan  = a_is_nan | b_is_nan | (a_is_zero & b_is_zero) | (a_is_inf & b_is_inf);
      result_is_inf  = a_is_inf | b_is_zero;
      result_is_zero = a_is_zero | b_is_inf;
    end else begin
      result_is_nan  = a_is_nan | b_is_nan | (a_is_inf & b_is_zero) | (a_is_zero & b_is_inf);
      result_is_inf  = a_is_inf | b_is_inf;
      result_is_zero = a_is_zero | b_is_zero;
    end

    if (result_is_nan)       special_case_result = 32'h7FC00000;
    else if (result_is_inf)  special_case_result = {sign_result, 8'hFF, 23'd0};
    else                     special_case_result = {sign_result, 31'd0};

    // Normalise operands
    mantissa_a_raw = (exponent_field_a == 8'h00) ? {1'b0, fraction_a} : {1'b1, fraction_a};
    mantissa_b_raw = (exponent_field_b == 8'h00) ? {1'b0, fraction_b} : {1'b1, fraction_b};

    leading_zeros_a = count_leading_zeros_24(mantissa_a_raw);
    leading_zeros_b = count_leading_zeros_24(mantissa_b_raw);

    mantissa_a = mantissa_a_raw << leading_zeros_a;
    mantissa_b = mantissa_b_raw << leading_zeros_b;

    if (exponent_field_a == 8'h00) exponent_a = -126 - leading_zeros_a;
    else                           exponent_a = exponent_field_a - 127;

    if (exponent_field_b == 8'h00) exponent_b = -126 - leading_zeros_b;
    else                           exponent_b = exponent_field_b - 127;
  end

  // 2) Combinational Multiplier
  logic [47:0] product;
  logic [47:0] multiply_mantissa; 
  integer      multiply_exponent; 

  always_comb begin
    product = mantissa_a * mantissa_b;
    if (product[47]) begin
      multiply_mantissa = product;
      multiply_exponent = exponent_a + exponent_b + 1;
    end else begin
      multiply_mantissa = {product[46:0], 1'b0};
      multiply_exponent = exponent_a + exponent_b;
    end
  end

  // 3) State registers
  logic [1:0]  state;
  logic        result_sign_reg;      
  integer      result_exponent_reg;  
  logic [47:0] result_mantissa_reg;  
  logic        sticky_reg;           
  logic [25:0] remainder_reg;        
  logic [23:0] divisor_reg;          
  logic [26:0] quotient_reg;         
  logic [4:0]  divide_step_reg;      

  // 4) Restoring-division step
  logic [25:0] remainder_after_subtract;
  logic [25:0] next_remainder;
  logic        quotient_bit;
  logic [26:0] next_quotient;

  always_comb begin
    quotient_bit = (remainder_reg >= {2'b00, divisor_reg});
    if (quotient_bit) remainder_after_subtract = remainder_reg - {2'b00, divisor_reg};
    else              remainder_after_subtract = remainder_reg;
    next_remainder = {remainder_after_subtract[24:0], 1'b0};
    next_quotient  = {quotient_reg[25:0], quotient_bit};
  end

  // 5) Rounding and packing
  logic [63:0] mantissa_wide;
  logic [63:0] dropped_bits_mask;
  logic [63:0] mantissa_shifted;
  logic        sticky_total;
  logic [23:0] mantissa_24;          
  logic [24:0] mantissa_rounded;     
  logic        guard_bit;
  logic        sticky_bit;
  logic        round_up;
  logic [39:0] exponent_base;        
  logic [39:0] packed_sum;
  integer      denormalize_shift;
  logic [31:0] rounded_result;

  always_comb begin
    if (result_exponent_reg < -126) begin
      denormalize_shift = -126 - result_exponent_reg;
      if (denormalize_shift > 60) denormalize_shift = 60;
      exponent_base = 40'd0;
    end else begin
      denormalize_shift = 0;
      exponent_base = result_exponent_reg + 126;
    end

    mantissa_wide     = {16'd0, result_mantissa_reg};
    dropped_bits_mask = (64'd1 << denormalize_shift) - 64'd1;
    mantissa_shifted  = mantissa_wide >> denormalize_shift;
    sticky_total      = sticky_reg | (|(mantissa_wide & dropped_bits_mask));

    mantissa_24      = mantissa_shifted[47:24];
    guard_bit        = mantissa_shifted[23];
    sticky_bit       = (|mantissa_shifted[22:0]) | sticky_total;
    round_up         = guard_bit & (sticky_bit | mantissa_24[0]); 
    mantissa_rounded = {1'b0, mantissa_24} + {24'd0, round_up};

    packed_sum = {exponent_base[16:0], 23'd0} + {15'd0, mantissa_rounded};

    if (packed_sum >= 40'h007F800000) rounded_result = {result_sign_reg, 8'hFF, 23'd0}; 
    else                              rounded_result = {result_sign_reg, packed_sum[30:0]};
  end

  // 6) Control FSM
  always_ff @(posedge clk) begin
    if (reset) begin
      state               <= STATE_IDLE;
      out_valid           <= 1'b0;
      result              <= 32'd0;
      result_sign_reg     <= 1'b0;
      result_exponent_reg <= 0;
      result_mantissa_reg <= 48'd0;
      sticky_reg          <= 1'b0;
      remainder_reg       <= 26'd0;
      divisor_reg         <= 24'd0;
      quotient_reg        <= 27'd0;
      divide_step_reg     <= 5'd0;
    end else begin
      out_valid <= 1'b0;

      case (state)
        STATE_IDLE: begin
          if (in_valid) begin
            if (result_is_nan | result_is_inf | result_is_zero) begin
              result    <= special_case_result;
              out_valid <= 1'b1;
            end else if (!div) begin
              result_sign_reg     <= sign_result;
              result_exponent_reg <= multiply_exponent;
              result_mantissa_reg <= multiply_mantissa;
              sticky_reg          <= 1'b0;
              state               <= STATE_ROUND;
            end else begin
              result_sign_reg     <= sign_result;
              result_exponent_reg <= exponent_a - exponent_b;
              remainder_reg       <= {2'b00, mantissa_a};
              divisor_reg         <= mantissa_b;
              quotient_reg        <= 27'd0;
              divide_step_reg     <= 5'd0;
              state               <= STATE_DIVIDE;
            end
          end
        end

        STATE_DIVIDE: begin
          remainder_reg   <= next_remainder;
          quotient_reg    <= next_quotient;
          divide_step_reg <= divide_step_reg + 5'd1;

          if (divide_step_reg == LAST_DIVIDE_STEP) begin
            sticky_reg <= |next_remainder;
            if (next_quotient[26]) begin
              result_mantissa_reg <= {next_quotient, 21'd0};
            end else begin
              result_mantissa_reg <= {next_quotient[25:0], 22'd0};
              result_exponent_reg <= result_exponent_reg - 1;
            end
            state <= STATE_ROUND;
          end
        end

        STATE_ROUND: begin
          result    <= rounded_result;
          out_valid <= 1'b1;
          state     <= STATE_IDLE;
        end

        default: state <= STATE_IDLE;
      endcase
    end
  end

endmodule