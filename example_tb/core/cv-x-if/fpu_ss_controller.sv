// Copyright 2021 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// FPU Subsystem Controller
// Contributor: Moritz Imfeld <moimfeld@student.ethz.ch>

module fpu_ss_controller #(
    parameter INT_REG_WB_DELAY = 1,
    parameter OUT_OF_ORDER = 1,
    parameter FORWARDING = 1
) (
    // clock and reset
    input logic clk_i,
    input logic rst_ni,

    // buffer pop handshake
    input  logic pop_valid_i,
    output logic pop_ready_o,
    input  logic fpu_busy_i,
    input  logic use_fpu_i,

    // FPnew input handshake
    output logic fpu_in_valid_o,
    input  logic fpu_in_ready_i,

    // FPnew output handshake
    input  logic fpu_out_valid_i,
    output logic fpu_out_ready_o,

    // register Write enable
    input  logic       rd_is_fp_i,
    input  logic [4:0] fpr_wb_addr_i,
    input  logic [4:0] rd_i,
    output logic       fpr_we_o,

    // c-response handshake
    input  logic c_p_ready_i,
    input  logic csr_wb_i,
    input  logic csr_instr_i,
    output logic c_p_valid_o,

    // dependency check
    input  logic                         rd_in_is_fp_i,
    input  logic                   [4:0] rs1_i,
    input  logic                   [4:0] rs2_i,
    input  logic                   [4:0] rs3_i,
    output logic                   [2:0] fwd_o,
    input  fpu_ss_pkg::op_select_e [2:0] op_select_i,

    // memory instruction handling
    input logic is_load_i,
    input logic is_store_i,

    // request Handshake
    output logic                   cmem_q_valid_o,
    input  logic                   cmem_q_ready_i,
    output acc_pkg::mem_req_type_e cmem_q_req_type_o,
    output logic                   cmem_q_mode_o,
    output logic                   cmem_q_spec_o,
    output logic                   cmem_q_endoftransaction_o,

    // response handshake
    input  logic cmem_p_valid_i,
    output logic cmem_p_ready_o,
    input  logic cmem_status_i,

    // additional signals
    output logic int_wb_o,
    output logic cmem_rsp_hs_o
);

  // status signals
  logic instr_inflight_d;
  logic instr_inflight_q;
  logic instr_offloaded_d;
  logic instr_offloaded_q;

  // scoreboard
  logic [31:0] scoreboard_d;
  logic [31:0] scoreboard_q;

  // dependencies
  logic dep_rs1;
  logic dep_rs2;
  logic dep_rs3;
  logic dep_rs;
  logic dep_rd;

  // INT_REG_WB_DELAY signals
  logic [INT_REG_WB_DELAY:0] delay_reg_d;
  logic [INT_REG_WB_DELAY:0] delay_reg_q;

  // handshakes
  logic c_rsp_hs;
  logic cmem_req_hs;

  assign c_rsp_hs = c_p_ready_i & c_p_valid_o;
  assign cmem_q_mode_o   = 1'b0; // no probing -> harwire to 0 (probing is only for external mode memory oerpations)
  assign cmem_q_spec_o = 1'b0;  // no speculative memory operations -> hardwire to 0
  assign cmem_p_ready_o = 1'b1;  // always accept writebacks from the core (e.g. loads)

  assign fpu_out_ready_o = ~cmem_rsp_hs_o;  // only don't accept writebacks from the FPnew when a memory instruction writes back to the fp register file
  assign cmem_req_hs = cmem_q_valid_o & cmem_q_ready_i;
  assign cmem_rsp_hs_o = cmem_p_valid_i & cmem_p_ready_o;

  // dependency check (used to avoid data hazards)
  assign dep_rs1 = scoreboard_q[rs1_i] & pop_valid_i & (op_select_i[0] == fpu_ss_pkg::RegA | op_select_i[1] == fpu_ss_pkg::RegA | op_select_i[2] == fpu_ss_pkg::RegA);
  assign dep_rs2 = scoreboard_q[rs2_i] & pop_valid_i & (op_select_i[0] == fpu_ss_pkg::RegB | op_select_i[1] == fpu_ss_pkg::RegB | op_select_i[2] == fpu_ss_pkg::RegB);
  assign dep_rs3 = scoreboard_q[rs3_i] & pop_valid_i & (op_select_i[0] == fpu_ss_pkg::RegC | op_select_i[1] == fpu_ss_pkg::RegC | op_select_i[2] == fpu_ss_pkg::RegC);
  assign dep_rs = (dep_rs1 & ~fwd_o[0]) | (dep_rs2 & ~fwd_o[1]) | (dep_rs3 & ~fwd_o[2]);
  assign dep_rd = scoreboard_q[rd_i] & rd_in_is_fp_i & ~(fpu_out_valid_i & rd_is_fp_i & (fpr_wb_addr_i == rd_i));

  // integer writeback delay assignement
  assign int_wb_o = delay_reg_q[INT_REG_WB_DELAY];

  // forwarding
  always_comb begin
    fwd_o[0] = 1'b0;
    fwd_o[1] = 1'b0;
    fwd_o[2] = 1'b0;
    if (FORWARDING) begin
      fwd_o[0] = dep_rs1 & fpu_out_valid_i & rd_is_fp_i & rs1_i == fpr_wb_addr_i;
      fwd_o[1] = dep_rs2 & fpu_out_valid_i & rd_is_fp_i & rs2_i == fpr_wb_addr_i;
      fwd_o[2] = dep_rs3 & fpu_out_valid_i & rd_is_fp_i & rs3_i == fpr_wb_addr_i;
    end
  end

  // pop instruction
  always_comb begin
    pop_ready_o = 1'b0;
    if ((fpu_in_valid_o & fpu_in_ready_i) | (c_rsp_hs & int_wb_o) | cmem_rsp_hs_o) begin
      pop_ready_o = 1'b1;
    end
  end

  // assert fpu_in_valid_o
  // - when instr uses fpu
  // - when there are no dependencies
  // - when fifo is NOT empty
  // Note: out-of-order execution is enabled/disabled here
  always_comb begin
    fpu_in_valid_o = 1'b0;
    if (use_fpu_i & pop_valid_i & ~dep_rs & ~dep_rd & OUT_OF_ORDER) begin
      fpu_in_valid_o = 1'b1;
    end else if (use_fpu_i  & pop_valid_i & ~dep_rs & ~dep_rd & (fpu_out_valid_i | ~instr_inflight_q) & ~OUT_OF_ORDER) begin
      fpu_in_valid_o = 1'b1;
    end
  end

  // assert fpr_we_o
  // - when fpu has a valid output and When rd is a fp register
  // - when instruction is load and the valid ready handshake of the cmem response channel occures
  always_comb begin
    fpr_we_o = 1'b0;
    if ((fpu_out_valid_i & rd_is_fp_i) | (is_load_i & cmem_rsp_hs_o)) begin
      fpr_we_o = 1'b1;
    end
  end

  // assert cmem_q_endoftransaction_o
  // - when the cmem-response handshake happend
  always_comb begin
    cmem_q_endoftransaction_o = 1'b0;
    if (cmem_req_hs) begin
      cmem_q_endoftransaction_o = 1'b1;
    end
  end

  // assert c_p_valid_o (integer register writeback) (c-response channel handshake)
  // - when fpu_out_valid_i is high
  // - when rd is NOT a fp register
  // - when int_wb is high (int_wb controlls integer register writebacks of instructions that do not go though the fpu (e.g. csr))
  always_comb begin
    c_p_valid_o = 1'b0;
    if ((fpu_out_valid_i & ~rd_is_fp_i) | (int_wb_o)) begin
      c_p_valid_o = 1'b1;
    end
  end

  // assert cmem_q_valid_o (load/store offload to the core)
  // - when the current instruction is a load/store instruction
  // - when the fifo is NOT empty
  // - when the instruction has NOT already been offloaded back to the core (instr_offloaded_q signal)
  always_comb begin
    cmem_q_valid_o = 1'b0;
    if ((is_load_i | is_store_i) & ~dep_rs & pop_valid_i & ~instr_offloaded_q & ~fpu_busy_i) begin
      cmem_q_valid_o = 1'b1;
    end
  end

  // set the cmem_q_req_type_o
  // - when is_load_i  -> req_type = READ
  // - when is_store_i -> req_type = WRITE
  always_comb begin
    cmem_q_req_type_o = acc_pkg::READ;
    if (is_store_i) begin
      cmem_q_req_type_o = acc_pkg::WRITE;
    end
  end

  // update for the instr_inflight status signal
  always_comb begin
    instr_inflight_d = instr_inflight_q;
    if ((fpu_out_valid_i & fpu_out_ready_o) & ~fpu_in_valid_o) begin
      instr_inflight_d = 1'b0;
    end else if (fpu_in_valid_o) begin
      instr_inflight_d = 1'b1;
    end
  end

  // update for the instr_offloaded status signal
  always_comb begin
    instr_offloaded_d = instr_offloaded_q;
    if (pop_valid_i & cmem_req_hs) begin
      instr_offloaded_d = 1'b1;
    end else if (cmem_rsp_hs_o) begin
      instr_offloaded_d = 1'b0;
    end
  end

  // update for the scoreboard
  always_comb begin
    scoreboard_d = scoreboard_q;
    if (fpu_in_valid_o & rd_in_is_fp_i) begin
      scoreboard_d[rd_i] = 1'b1;
    end
    if ((fpu_out_ready_o & fpu_out_valid_i) & ~(fpu_in_valid_o & fpu_in_ready_i & fpr_wb_addr_i == rd_i)) begin
      scoreboard_d[fpr_wb_addr_i] = 1'b0;
    end
  end

  // status signal register
  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (~rst_ni) begin
      instr_inflight_q  <= 1'b0;
      instr_offloaded_q <= 1'b0;
      scoreboard_q      <= '0;
    end else begin
      instr_inflight_q  <= instr_inflight_d;
      instr_offloaded_q <= instr_offloaded_d;
      scoreboard_q      <= scoreboard_d;
    end
  end

  // start integer delay when:
  // - when there is a csr instruction
  // - when there is an instruction that does not use the fpu, does write back to an integer register and is not a load or store
  always_comb begin
    delay_reg_q[0] = 1'b0;
    if (pop_valid_i & (csr_instr_i | (~use_fpu_i & ~is_load_i & ~is_store_i))) begin
      delay_reg_q[0] = 1'b1;
    end
  end

  // register array that delays integer writebacks which do not go through the fpu
  // - this can be used to break the critical path of instructions that would otherwise write back to the core
  //   in the same cycle as they were offloaded
  for (genvar i = 0; i < INT_REG_WB_DELAY; i++) begin
    always_comb begin
      delay_reg_d[i+1] = delay_reg_q[i];
      if (~delay_reg_q[0] | pop_ready_o | fpu_busy_i | fpu_out_valid_i | is_load_i | is_store_i | ~pop_valid_i) begin
        delay_reg_d[i+1] = 1'b0;
      end
    end

    always_ff @(posedge clk_i, negedge rst_ni) begin
      if (~rst_ni) begin
        delay_reg_q[i+1] <= '0;
      end else begin
        delay_reg_q[i+1] <= delay_reg_d[i+1];
      end
    end
  end

endmodule : fpu_ss_controller
