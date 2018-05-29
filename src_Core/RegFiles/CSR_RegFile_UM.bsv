// Copyright (c) 2016-2018 Bluespec, Inc. All Rights Reserved

package CSR_RegFile_UM;

// ================================================================
// CSR (Control and Status Register) Register File

// This version has all the User- and Machine- privilege registers.

// ================================================================
// Exports

export  CSR_RegFile_IFC (..),  mkCSR_RegFile;

// ================================================================
// BSV library imports

import ConfigReg    :: *;
import RegFile      :: *;
import Vector       :: *;
import FIFOF        :: *;
import GetPut       :: *;
import ClientServer :: *;

// BSV additional libs

import Cur_Cycle  :: *;
import GetPut_Aux :: *;

// ================================================================
// Project imports

import ISA_Decls :: *;

`ifdef INCLUDE_GDB_CONTROL
import DM_Common :: *;    // Debug Module defs
`endif

// ================================================================

interface CSR_RegFile_IFC;
   // Reset
   interface Server #(Token, Token) server_reset;

   // CSR read (w.o. side effect)
   (* always_ready *)
   method Maybe #(Word) read_csr (CSR_Addr csr_addr);
   (* always_ready *)
   method Maybe #(Word) read_csr_port2 (CSR_Addr csr_addr);

   // CSR read (w. side effect)
   (* always_ready *)
   method ActionValue #(Maybe #(Word)) mav_read_csr (CSR_Addr csr_addr);

   // CSR write
   (* always_ready *)
   method Action write_csr (CSR_Addr csr_addr, Word word);

   // Read SATP
   (* always_ready *)
   method WordXL read_satp;

   // Read MSTATUS
   (* always_ready *)
   method WordXL read_mstatus;

   // Read SSTATUS
   (* always_ready *)
   method WordXL read_sstatus;

   // CSR trap actions
   method ActionValue #(Tuple4 #(Addr, Word, Word, Priv_Mode))
          csr_trap_actions (Priv_Mode  from_priv,
			    Word       pc,
			    Bool       interrupt,
			    Exc_Code   exc_code,
			    Word       xtval);

   // CSR RET actions (return from exception)
   method ActionValue #(Tuple3 #(Addr, Priv_Mode, Word)) csr_ret_actions (Priv_Mode from_priv);

   // Read MINSTRET
   (* always_ready *)
   method Bit #(64) read_csr_minstret;

   // Increment MINSTRET
   (* always_ready *)
   method Action csr_minstret_incr;

   // Read MCYCLE
   (* always_ready *)
   method Bit #(64) read_csr_mcycle;

   // Read MTIME
   (* always_ready *)
   method Bit #(64) read_csr_mtime;

   // Read MCOUNTEREN
   (* always_ready *)
   method MCounteren read_csr_mcounteren;

   // Interrupts
   (* always_ready *)
   method Action external_interrupt_req;
   (* always_ready *)
   method Action timer_interrupt_req;
   (* always_ready *)
   method Action software_interrupt_req;

   (* always_ready *)
   method Maybe #(Exc_Code) interrupt_pending (Priv_Mode cur_priv);

   // ----------------
   // Methods when Debug Module is present

`ifdef INCLUDE_GDB_CONTROL
   // Read dpc
   method Word read_dpc ();

   // Update dpc
   method Action write_dpc (Addr pc);

   // Break should enter Debug Mode
   method Bool dcsr_break_enters_debug (Priv_Mode cur_priv);

   // Read dcsr.step
   method Bool read_dcsr_step ();

   // Update 'cause' in DCSR
   (* always_ready *)
   method Action write_dcsr_cause (DCSR_Cause cause);

   (* always_ready *)
   method WordXL watchpoint_hit (WordXL addr);

   (* always_ready *)
   method Action set_watch_n (WordXL n);
`endif

endinterface

// ================================================================
// 'misa' specifying RSIC-V features implemented.

function MISA misa_reset_value;
   MISA ms = unpack (0);

`ifdef RV32
   ms.mxl = misa_mxl_32;
`elsif RV64
   ms.mxl = misa_mxl_64;
`elsif RV128
   ms.mxl = misa_mxl_128;
`else
   ms.mxl = misa_mxl_default;
`endif

`ifdef ISA_PRIV_U
   // User Mode
   ms.u = 1'b1;
`ifdef ISA_N
   // User-level Interrupts
   ms.n = 1'b1;
`endif
`endif

`ifdef ISA_PRIV_S
   // Supervisor Mode
   ms.s = 1'b1;
`endif

   // Integer Base
   ms.i = 1'b1;

`ifdef ISA_M
   // Integer Multiply/Divide
   ms.m = 1'b1;
`endif

`ifdef ISA_FD
   // Single- and Double-precision Floating Point
   ms.f = 1'b1;
   ms.d = 1'b1;
`endif

`ifdef ISA_A
   // Atomic Memory Ops
   ms.a = 1'b1;
`endif

`ifdef ISA_C
   // Compressed Instructions
   ms.c = 1'b1;
`endif

   return ms;
endfunction

// ================================================================
// mtvec reset value    TODO: still relevant? No longer part of the spec?

Word mtvec_reset_value = 'h0100;    // TODO: this is no longer standard?

// ================================================================
// Major states of mkCSR_RegFile module

typedef enum { RF_RESET_START, RF_RUNNING } RF_State
deriving (Eq, Bits, FShow);

// ================================================================

(* synthesize *)
module mkCSR_RegFile (CSR_RegFile_IFC);

   Reg #(Bit #(4)) cfg_verbosity <- mkConfigReg (0);
   Reg #(RF_State) rg_state      <- mkReg (RF_RESET_START);

   Reg #(Bool) rg_ei_requested <- mkRegU;    // External interrupt requested
   Reg #(Bool) rg_ti_requested <- mkRegU;    // Timer    interrupt requested
   Reg #(Bool) rg_si_requested <- mkRegU;    // Software interrupt requested

   // Reset
   FIFOF #(Token) f_reset_rsps <- mkFIFOF;

   // Supervisor-mode CSRs
   Bit #(16)  sedeleg = 0;    // hardwired to 0
   Bit #(12)  sideleg = 0;    // hardwired to 0

`ifdef ISA_PRIV_S
   // sstatus is a restricted view of mstatus

   Reg #(MIE)        rg_sie       <- mkRegU;
   Reg #(MTVec)      rg_stvec     <- mkRegU;
   // scounteren hardwired to 0 for now

   Reg #(Word)       rg_sscratch  <- mkRegU;
   Reg #(Word)       rg_sepc      <- mkRegU;
   Reg #(MCause)     rg_scause    <- mkRegU;
   Reg #(Word)       rg_stval     <- mkRegU;
   Reg #(MIP)        rg_sip       <- mkRegU;

   Reg #(WordXL)     rg_satp      <- mkRegU;

   Reg #(Bit #(16))  rg_medeleg   <- mkRegU;    // TODO: also in M-U systems with user-level traps
   Reg #(Bit #(12))  rg_mideleg   <- mkRegU;    // TODO: also in M-U systems with user-level traps
`else
   Bit #(16)         rg_medeleg   = 0;
   Bit #(12)         rg_mideleg   = 0;
`endif

   // CSRs
   // Machine-mode CSRs
   Word mvendorid   = 0;    // Not implemented
   Word marchid     = 0;    // Not implemented
   Word mimpid      = 0;    // Not implemented
   Word mhartid     = 0;

   Reg #(MStatus)    rg_mstatus    <- mkReg (mstatus_reset_value);
   MISA              misa          =  misa_reset_value;
   Reg #(MIE)        rg_mie        <- mkRegU;
   Reg #(MTVec)      rg_mtvec      <- mkRegU;
   Reg #(MCounteren) rg_mcounteren <- mkRegU;

   Reg #(Word)       rg_mscratch <- mkRegU;
   Reg #(Word)       rg_mepc     <- mkRegU;
   Reg #(MCause)     rg_mcause   <- mkRegU;
   Reg #(Word)       rg_mtval    <- mkRegU;
   Reg #(MIP)        rg_mip      <- mkRegU;

   // RegFile #(Bit #(2), WordXL)  rf_pmpcfg   <- mkRegFileFull;
   // Vector #(16, Reg #(WordXL))  vrg_pmpaddr <- replicateM (mkRegU);

   // mcycle is needed even for user-mode instructions
   // It can be updated by a CSR instruction (in Priv_M), and by the clock
   Reg #(Bit #(64))   rg_mcycle <- mkReg (0);
   RWire #(Bit #(64)) rw_mcycle <- mkRWire;    // Driven on CSRRx write to mcycle

   // minstret is needed even for user-mode instructions
   // It can be updated by a CSR instruction (in Priv_M), and by retirement of any other instruction
   Reg #(Bit #(64))   rg_minstret      <- mkReg (0);    // Needed even for user-mode instrs
   RWire #(Bit #(64)) rw_minstret      <- mkRWire;      // Driven on CSRRx write to minstret
   PulseWire          pw_minstret_incr <- mkPulseWire;

`ifdef INCLUDE_GDB_CONTROL
   Reg #(Word)      rg_dpc  <- mkRegU;
   Reg #(Bit #(32)) rg_dcsr <- mkRegU;    // Is 32b even in RV64
`endif

   // ----------------
   // Non-standard 'watchpoint' CSRs
   // rg_watchpoint1, 2, ..  contain mem addrs to be watched for accesses
   // On a watchpoint hit, rg_watch_n holds the watchpoint reg number (1..) that matched
   // rg_watch_n is a read-only register, and resets to 0

   // TODO: Each watchpoint should have a status of disarmed/armed
   // (for now, '1 is just an 'unlikely' watchpoint, so is disarmed)
   Reg #(WordXL)  rg_watch_n     <- mkReg (0);

   Reg #(WordXL)  rg_watchpoint1 <- mkReg ('1);
   // Reg #(WordXL)  rg_watchpoint1 <- mkReg ('hC000_0000);   // UART tx, for testing

   // ----------------------------------------------------------------
   // Reset.
   // Initialize some CSRs.

   rule rl_reset_start (rg_state == RF_RESET_START);
      rg_ei_requested <= False;
      rg_ti_requested <= False;
      rg_si_requested <= False;

`ifdef ISA_PRIV_S
      rg_sie      <= word_to_mie (0);
      rg_stvec    <= word_to_mtvec (mtvec_reset_value);
      rg_scause   <= word_to_mcause (0);    // Supposed to be the cause of the reset.
      rg_sip      <= word_to_mip (0);
      rg_satp     <= 0;
      //rg_scounteren <= mcounteren_reset_value;
`endif

      rg_mstatus  <= mstatus_reset_value;
      rg_mie      <= word_to_mie (0);
      rg_mtvec    <= word_to_mtvec (mtvec_reset_value);
      rg_mcause   <= word_to_mcause (0);    // Supposed to be the cause of the reset.
      rg_mip      <= word_to_mip (0);
      rg_mcounteren <= mcounteren_reset_value;

      rw_minstret.wset (0);

`ifdef INCLUDE_GDB_CONTROL
      // rg_dpc  <= pc_reset_value;    // Should be set by GDB
      rg_dcsr <= zeroExtend ({4'h4,    // xdebugver
			      12'h0,   // reserved
			      1'h1,    // ebreakm
			      1'h0,    // reserved
			      1'h1,    // ebreaks
			      1'h1,    // ebreaku
			      1'h0,    // stepie
			      1'h0,    // stepcount
			      1'h0,    // steptime
			      3'h0,    // cause    // WARNING: 0 is non-standard
			      3'h0,    // reserved
			      1'h0,    // step
			      2'h0}    // prv
			     );
`endif

      rg_watch_n <= 0;

      rg_state <= RF_RUNNING;
   endrule

   // ----------------------------------------------------------------
   // CYCLE counter

   (* no_implicit_conditions, fire_when_enabled *)
   rule rl_mcycle_incr;
      // Update due to CSRRx
      if (rw_mcycle.wget matches tagged Valid .v)
	 rg_mcycle <= rg_mcycle + 1;

      // Update due to clock
      else
	 rg_mcycle <= rg_mcycle + 1;
   endrule

   // ----------------------------------------------------------------
   // INSTRET

   (* descending_urgency = "rl_reset_start, rl_upd_minstret_csrrx" *)
   rule rl_upd_minstret_csrrx (rw_minstret.wget matches tagged Valid .v);
      rg_minstret <= v;
      // $display ("%0d: CSR_RegFile_UM.rl_upd_minstret_csrrx: new value is %0d", cur_cycle, v);
   endrule

   (* no_implicit_conditions, fire_when_enabled *)
   rule rl_upd_minstret_incr ((! isValid (rw_minstret.wget)) && pw_minstret_incr);
      rg_minstret <= rg_minstret + 1;
      // $display ("%0d: CSR_RegFile_UM.rl_upd_minstret_incr: new value is %0d", cur_cycle, rg_minstret + 1);
   endrule

   // ----------------------------------------------------------------
   // Help functions for interface methods

   // ----------------
   // CSR reads (no side effect)
   // Returns Invalid for invalid CSR addresses or access-mode violations

   function Maybe #(Word) fv_csr_read (CSR_Addr csr_addr);
      Maybe #(Word)  m_csr_value = tagged Invalid;

      case (csr_addr)
	 // User mode csrs
`ifdef ISA_FD
	 // TODO: fixup when we implement FD
	 csr_fflags:    m_csr_value = tagged Valid 0;
	 csr_frm:       m_csr_value = tagged Valid 0;
	 csr_fcsr:      m_csr_value = tagged Valid 0;
`endif

	 csr_cycle:     m_csr_value = tagged Valid (truncate (rg_mcycle));
	 csr_time:      m_csr_value = tagged Valid (truncate (rg_mcycle)); // S
	 csr_instret:   m_csr_value = tagged Valid (truncate (rg_minstret));
`ifdef RV32
	 csr_cycleh:    m_csr_value = tagged Valid (rg_mcycle   [63:32]);
	 csr_timeh:     m_csr_value = tagged Valid (rg_mcycle   [63:32]);
	 csr_instreth:  m_csr_value = tagged Valid (rg_minstret [63:32]);
`endif

`ifdef ISA_PRIV_S
	 csr_sstatus:   m_csr_value = tagged Valid (fn_read_sstatus (rg_mstatus));
	 csr_sedeleg:   m_csr_value = tagged Valid zeroExtend (sedeleg);
	 csr_sideleg:   m_csr_value = tagged Valid zeroExtend (sideleg);
	 csr_sie:       m_csr_value = tagged Valid (mie_to_word (rg_sie));
	 csr_stvec:     m_csr_value = tagged Valid (mtvec_to_word (rg_stvec));
	 csr_scounteren:m_csr_value = tagged Valid 0;

	 csr_sscratch:  m_csr_value = tagged Valid rg_sscratch;
	 csr_sepc:      m_csr_value = tagged Valid rg_sepc;
	 csr_scause:    m_csr_value = tagged Valid (mcause_to_word (rg_scause));
	 csr_stval:     m_csr_value = tagged Valid rg_stval;
	 csr_sip:       m_csr_value = tagged Valid (mip_to_word (rg_sip));

	 csr_satp:      m_csr_value = tagged Valid 0;    // hardwired to 0 (Bare more only)

	 csr_medeleg:   m_csr_value = tagged Valid zeroExtend (rg_medeleg);
	 csr_mideleg:   m_csr_value = tagged Valid zeroExtend (rg_mideleg);
`endif

	 // Machine mode csrs
	 csr_mvendorid: m_csr_value = tagged Valid mvendorid;
	 csr_marchid:   m_csr_value = tagged Valid marchid;
	 csr_mimpid:    m_csr_value = tagged Valid mimpid;
	 csr_mhartid:   m_csr_value = tagged Valid mhartid;

	 csr_mstatus:   m_csr_value = tagged Valid (mstatus_to_word (rg_mstatus));
	 csr_misa:      m_csr_value = tagged Valid (misa_to_word (misa));
	 csr_mie:       m_csr_value = tagged Valid (mie_to_word (rg_mie));
	 csr_mtvec:     m_csr_value = tagged Valid (mtvec_to_word (rg_mtvec));
	 csr_mcounteren:m_csr_value = tagged Valid (mcounteren_to_word (rg_mcounteren));

	 csr_mscratch:  m_csr_value = tagged Valid rg_mscratch;
	 csr_mepc:      m_csr_value = tagged Valid rg_mepc;
	 csr_mcause:    m_csr_value = tagged Valid (mcause_to_word (rg_mcause));
	 csr_mtval:     m_csr_value = tagged Valid rg_mtval;
	 csr_mip:       m_csr_value = tagged Valid (mip_to_word (rg_mip));

	 // csr_pmpcfg0:   m_csr_value = tagged Valid rf_pmpcfg.sub (0);
	 // csr_pmpcfg1:   m_csr_value = tagged Valid rf_pmpcfg.sub (1);
	 // csr_pmpcfg2:   m_csr_value = tagged Valid rf_pmpcfg.sub (2);
	 // csr_pmpcfg3:   m_csr_value = tagged Valid rf_pmpcfg.sub (3);

	 // csr_pmpaddr0:   m_csr_value = tagged Valid vrg_pmpaddr [0];
	 // csr_pmpaddr1:   m_csr_value = tagged Valid vrg_pmpaddr [1];
	 // csr_pmpaddr2:   m_csr_value = tagged Valid vrg_pmpaddr [2];
	 // csr_pmpaddr3:   m_csr_value = tagged Valid vrg_pmpaddr [3];
	 // csr_pmpaddr4:   m_csr_value = tagged Valid vrg_pmpaddr [4];
	 // csr_pmpaddr5:   m_csr_value = tagged Valid vrg_pmpaddr [5];
	 // csr_pmpaddr6:   m_csr_value = tagged Valid vrg_pmpaddr [6];
	 // csr_pmpaddr7:   m_csr_value = tagged Valid vrg_pmpaddr [7];
	 // csr_pmpaddr8:   m_csr_value = tagged Valid vrg_pmpaddr [8];
	 // csr_pmpaddr9:   m_csr_value = tagged Valid vrg_pmpaddr [9];
	 // csr_pmpaddr10:  m_csr_value = tagged Valid vrg_pmpaddr [10];
	 // csr_pmpaddr11:  m_csr_value = tagged Valid vrg_pmpaddr [11];
	 // csr_pmpaddr12:  m_csr_value = tagged Valid vrg_pmpaddr [12];
	 // csr_pmpaddr13:  m_csr_value = tagged Valid vrg_pmpaddr [13];
	 // csr_pmpaddr14:  m_csr_value = tagged Valid vrg_pmpaddr [14];
	 // csr_pmpaddr15:  m_csr_value = tagged Valid vrg_pmpaddr [15];

	 csr_mcycle:    m_csr_value = tagged Valid (truncate (rg_mcycle));
	 csr_minstret:  m_csr_value = tagged Valid (truncate (rg_minstret));
`ifdef RV32
	 csr_mcycleh:   m_csr_value = tagged Valid (rg_mcycle [63:32]);
	 csr_minstreth: m_csr_value = tagged Valid (rg_minstret [63:32]);
`endif

`ifdef INCLUDE_GDB_CONTROL
	 csr_addr_dpc:  m_csr_value = tagged Valid rg_dpc;
	 csr_addr_dcsr: m_csr_value = tagged Valid zeroExtend (rg_dcsr);
`endif

	 csr_addr_watch_n:     m_csr_value = tagged Valid rg_watch_n;
	 csr_addr_watchpoint1: m_csr_value = tagged Valid rg_watchpoint1;

	 default: m_csr_value = tagged Invalid;
      endcase
      return m_csr_value;
   endfunction
   
   // ----------------
   // CSR writes
   // Returns True if successful
   // If unsuccessful, should trap (illegal CSR).

   function Action fav_write_csr (CSR_Addr csr_addr, Word word);
      action
	 Bool success = True;
	 case (csr_addr)
	    // User mode csrs
`ifdef ISA_FD
	    // TODO: fixup when we implemen FD
	    csr_fflags:    noAction;
	    csr_frm:       noAction;
	    csr_fcsr:      noAction;
`endif

`ifdef ISA_PRIV_S
	    csr_sstatus:    rg_mstatus    <= fn_write_sstatus (rg_mstatus, word);
	    csr_sedeleg:    noAction;               // Hardwired to 0 (no delegation)
	    csr_sideleg:    noAction;               // Hardwired to 0 (no delegation)
	    csr_sie:        rg_sie        <= word_to_mie (word);
	    csr_stvec:      rg_stvec      <= word_to_mtvec (word);
	    csr_scounteren: noAction;

	    csr_sscratch:   rg_sscratch <= word;
	    csr_sepc:       rg_sepc     <= word;
	    csr_scause:     rg_scause   <= word_to_mcause (word);
	    csr_stval:      rg_stval    <= word;
	    csr_sip:        rg_sip      <= word_to_mip (word);

	    csr_satp:       rg_satp <= word;

	    csr_medeleg:    rg_medeleg <= (truncate (word) & 'h_B3FF);  // 16 bits relevant and some are 0
	    csr_mideleg:    rg_mideleg <= (truncate (word) & 'h_0FFF);  // 12 bits relevant
`endif

	    // Machine mode
	    csr_mvendorid: noAction;
	    csr_marchid:   noAction;
	    csr_mimpid:    noAction;
	    csr_mhartid:   noAction;

	    csr_mstatus:   rg_mstatus    <= word_to_mstatus (word);
	    csr_misa:      noAction;
	    csr_mie:       rg_mie        <= word_to_mie (word);
	    csr_mtvec:     rg_mtvec      <= word_to_mtvec(word);
	    csr_mcounteren:rg_mcounteren <= word_to_mcounteren(word);

	    csr_mscratch:  rg_mscratch <= word;
	    csr_mepc:      rg_mepc <= word;
	    csr_mcause:    rg_mcause <= word_to_mcause (word);
	    csr_mtval:     rg_mtval <= word;
	    csr_mip:       rg_mip <= word_to_mip (word);

	    // csr_pmpcfg0:   rf_pmpcfg.upd (0, word);
	    // csr_pmpcfg1:   rf_pmpcfg.upd (1, word);
	    // csr_pmpcfg2:   rf_pmpcfg.upd (2, word);
	    // csr_pmpcfg3:   rf_pmpcfg.upd (3, word);

	    // csr_pmpaddr0:  vrg_pmpaddr [0] <= word;
	    // csr_pmpaddr1:  vrg_pmpaddr [1] <= word;
	    // csr_pmpaddr2:  vrg_pmpaddr [2] <= word;
	    // csr_pmpaddr3:  vrg_pmpaddr [3] <= word;
	    // csr_pmpaddr4:  vrg_pmpaddr [4] <= word;
	    // csr_pmpaddr5:  vrg_pmpaddr [5] <= word;
	    // csr_pmpaddr6:  vrg_pmpaddr [6] <= word;
	    // csr_pmpaddr7:  vrg_pmpaddr [7] <= word;
	    // csr_pmpaddr8:  vrg_pmpaddr [8] <= word;
	    // csr_pmpaddr9:  vrg_pmpaddr [9] <= word;
	    // csr_pmpaddr10: vrg_pmpaddr [10] <= word;
	    // csr_pmpaddr11: vrg_pmpaddr [11] <= word;
	    // csr_pmpaddr12: vrg_pmpaddr [12] <= word;
	    // csr_pmpaddr13: vrg_pmpaddr [13] <= word;
	    // csr_pmpaddr14: vrg_pmpaddr [14] <= word;
	    // csr_pmpaddr15: vrg_pmpaddr [15] <= word;

`ifdef RV32
	    csr_mcycle:    rw_mcycle.wset   ({ rg_mcycle   [63:32], word });
	    csr_minstret:  rw_minstret.wset ({ rg_minstret [63:32], word });
	    csr_mcycleh:   rw_mcycle.wset   ({ word, rg_mcycle   [31:0] });
	    csr_minstreth: rw_minstret.wset ({ word, rg_minstret [31:0] });
`else
	    csr_mcycle:    rw_mcycle.wset   (word);
	    csr_minstret:  rw_minstret.wset (word);
`endif

`ifdef INCLUDE_GDB_CONTROL
	    csr_addr_dpc:  rg_dpc  <= word;
	    csr_addr_dcsr: rg_dcsr <= zeroExtend ({rg_dcsr [31:28],    // xdebugver: read-only
						   word [27:9],        // ebreakm/s/u, stepie, stopcount, stoptime
						   rg_dcsr [8:6],      // cause: read-only
						   word [5:0]}         // step, prv
						  );
`endif

	    csr_addr_watch_n:     noAction;
	    csr_addr_watchpoint1: rg_watchpoint1 <=word;

	    default:       success = False;
	 endcase
	 if ((! success) && (cfg_verbosity > 1))
	    $display ("%0d: ERROR: CSR-write addr 0x%0h val 0x%0h not successful", cur_cycle,
		      csr_addr, word);
      endaction
   endfunction

   // ----------------------------------------------------------------
   // Interrupt requests

   (* execution_order = "read_csr,  rl_record_external_interrupt" *)
   (* execution_order = "write_csr, rl_record_external_interrupt" *)
   rule rl_record_external_interrupt (rg_ei_requested);
      let mip = rg_mip;
      mip.eips [m_Priv_Mode] = 1'b1;
      rg_mip <= mip;
      rg_ei_requested <= False;
   endrule

   (* execution_order = "read_csr,  rl_record_timer_interrupt" *)
   (* execution_order = "write_csr, rl_record_timer_interrupt" *)
   rule rl_record_timer_interrupt (rg_ti_requested);
      let mip = rg_mip;
      mip.tips [m_Priv_Mode] = 1'b1;
      rg_mip <= mip;
      rg_ti_requested <= False;
   endrule

   (* execution_order = "read_csr,  rl_record_software_interrupt" *)
   (* execution_order = "write_csr, rl_record_software_interrupt" *)
   rule rl_record_software_interrupt (rg_si_requested);
      let mip = rg_mip;
      mip.sips [m_Priv_Mode] = 1'b1;
      rg_mip <= mip;
      rg_si_requested <= False;
   endrule

   // ================================================================
   // For debugging

   function Action fa_show_trap_csrs (Priv_Mode priv,
				      MIP ip, MIE ie,
				      Bit #(16) edeleg, Bit #(12) ideleg,
				      MCause cause, MStatus status, MTVec tvec,
				      WordXL epc, WordXL tval);
      action
	 $write ("    priv %0d: ", priv);
	 $write (" ip: 0x%0h", mip_to_word (ip));
	 $write (" ie: 0x%0h", mie_to_word (ie));
	 $write (" edeleg: 0x%0h", edeleg);
	 $write (" ideleg: 0x%0h", ideleg);
	 $write (" cause:", fshow (cause));
	 $display ("");

	 $write ("        ");
	 $write (" status: 0x%0h", mstatus_to_word (status));
	 $write (" tvec: 0x%0h", mtvec_to_word (tvec));
	 $write (" epc: 0x%0h", epc);
	 $write (" tval: 0x%0h", tval);
	 $display ("");
      endaction
   endfunction

   // ================================================================
   // INTERFACE

   // Reset
   interface Server server_reset;
      interface Put request;
	 method Action put (Token token);
	    rg_state <= RF_RESET_START;

	    // This response is placed here, and not in rl_reset_loop, because
	    // reset_loop can happen on power-up, where no response is expected.
	    f_reset_rsps.enq (?);
	 endmethod
      endinterface
      interface Get response;
	 method ActionValue #(Token) get if (rg_state == RF_RUNNING);
	    let token <- pop (f_reset_rsps);
	    return token;
	 endmethod
      endinterface
   endinterface

   // CSR read (w.o. side effect)
   method Maybe #(Word) read_csr (CSR_Addr csr_addr);
      return fv_csr_read (csr_addr);
   endmethod

   // CSR read (w.o. side effect)
   method Maybe #(Word) read_csr_port2 (CSR_Addr csr_addr);
      return fv_csr_read (csr_addr);
   endmethod

   // CSR read (w. side effect)
   method ActionValue #(Maybe #(Word)) mav_read_csr (CSR_Addr csr_addr);
      return fv_csr_read (csr_addr);
   endmethod

   // CSR write
   method Action write_csr (CSR_Addr csr_addr, Word word);
      fav_write_csr (csr_addr, word);
   endmethod

   // Read MSTATUS
   method WordXL read_mstatus;
      return  mstatus_to_word (rg_mstatus);
   endmethod

   // Read SSTATUS
   method WordXL read_sstatus;
      return  fn_read_sstatus (rg_mstatus);
   endmethod

   // Read SATP
   method WordXL read_satp;
`ifdef ISA_PRIV_S
      return  rg_satp;
`else
      return  ?;
`endif
   endmethod

   // CSR Trap actions
   method ActionValue #(Tuple4 #(Addr, Word, Word, Priv_Mode))
          csr_trap_actions (Priv_Mode  from_priv,
			    Word       pc,
			    Bool       interrupt,
			    Exc_Code   exc_code,
			    Word       xtval);

      if (cfg_verbosity > 1) begin
	 $display ("%0d: CSR_Regfile.csr_trap_actions:", cur_cycle);
	 $display ("    from priv %0d  pc 0x%0h  interrupt %0d  exc_code %0d  xtval 0x%0h",
		   from_priv, pc, pack (interrupt), exc_code, xtval);
`ifdef ISA_PRIV_S
	 fa_show_trap_csrs (s_Priv_Mode, rg_sip, rg_sie, 0, 0, rg_scause,
			    word_to_mstatus (fn_read_sstatus (rg_mstatus)),
			    rg_stvec, rg_sepc, rg_stval);
`endif
	 fa_show_trap_csrs (m_Priv_Mode, rg_mip, rg_mie, rg_medeleg, rg_mideleg, rg_mcause,
			    rg_mstatus,
			    rg_mtvec, rg_mepc, rg_mtval);
      end

      let new_priv    = fn_new_priv_on_exception (from_priv,
						  interrupt,
						  exc_code,
						  rg_medeleg,
						  rg_mideleg,
						  sedeleg,
						  sideleg);
      let new_mstatus = fn_mstatus_upd_on_trap (rg_mstatus, from_priv, new_priv);
      rg_mstatus     <= new_mstatus;

      Reg #(Word)   rg_xepc   = rg_mepc;
      Reg #(MCause) rg_xcause = rg_mcause;
      Reg #(Word)   rg_xtval  = rg_mtval;
      Reg #(MTVec)  rg_xtvec  = rg_mtvec;
`ifdef ISA_PRIV_S
      if (new_priv != m_Priv_Mode) begin
         rg_xepc   = rg_sepc;
         rg_xcause = rg_scause;
         rg_xtval  = rg_stval;
         rg_xtvec  = rg_stvec;
      end
`endif

      rg_xepc        <= pc;
      let xcause      = MCause {interrupt: pack (interrupt), exc_code: exc_code};
      rg_xcause      <= xcause;

      // xTVal is recorded only for exceptions
      if (! interrupt)
	 rg_xtval <= xtval;
      
      // Compute the exception PC based on the xTVEC mode bits
      Addr exc_pc     = (extend (rg_xtvec.base)) << 2;
      Addr vector_offset = (extend (exc_code)) << 2;
      if ((interrupt) && (rg_xtvec.mode == VECTORED))
	 exc_pc = exc_pc + vector_offset;

      if (cfg_verbosity > 1) begin
	 $write ("    Return: new pc 0x%0h  ", exc_pc);
	 $write (" new mstatus:", fshow (new_mstatus));
	 $write (" new xcause:", fshow (xcause));
	 $write (" new priv %0d", new_priv);
	 $display ("");
      end

      return tuple4 (exc_pc,                             // New PC
		     mstatus_to_word (new_mstatus),      // New mstatus
		     mcause_to_word  (xcause),           // New mcause
		     new_priv);                          // New priv
   endmethod

   // CSR RET actions (return from exception)
   method ActionValue #(Tuple3 #(Addr, Priv_Mode, Word)) csr_ret_actions (Priv_Mode from_priv);
      match { .new_mstatus, .to_priv } = fn_mstatus_upd_on_ret (rg_mstatus, from_priv);
      rg_mstatus  <= new_mstatus;
      Word next_pc = rg_mepc;
`ifdef ISA_PRIV_S
      if (from_priv != m_Priv_Mode)
	 next_pc = rg_sepc;
`endif
      return tuple3 (next_pc, to_priv, mstatus_to_word (new_mstatus));
   endmethod

   // Read MINSTRET
   method Bit #(64) read_csr_minstret;
      return rg_minstret;
   endmethod

   // Increment MINSTRET
   method Action csr_minstret_incr;
      pw_minstret_incr.send;
   endmethod

   // Read MCYCLE
   method Bit #(64) read_csr_mcycle;
      return rg_mcycle;
   endmethod

   // Read MTIME
   method Bit #(64) read_csr_mtime;
      // We use mcycle as a proxy for time
      return rg_mcycle;
   endmethod

   // Read MCOUNTEREN
   method MCounteren read_csr_mcounteren;
      return rg_mcounteren;
   endmethod

   // Interrupts
   method Action  external_interrupt_req;
      rg_ei_requested <= True;
   endmethod

   method Action  timer_interrupt_req;
      rg_ti_requested <= True;
   endmethod

   method Action  software_interrupt_req;
      rg_si_requested <= True;
   endmethod

   method Maybe #(Exc_Code) interrupt_pending (Priv_Mode cur_priv);
      return fn_interrupt_pending (mstatus_to_word (rg_mstatus),
				   mip_to_word     (rg_mip),
				   mie_to_word     (rg_mie),
				   cur_priv);
   endmethod

   // ----------------
   // Methods when Debug Module is present

`ifdef INCLUDE_GDB_CONTROL
   // Read dpc
   method Word read_dpc ();
      return rg_dpc;
   endmethod

   // Update dpc
   method Action write_dpc (Addr pc);
      rg_dpc <= pc;
   endmethod

   // Break should enter Debug Mode
   method Bool dcsr_break_enters_debug (Priv_Mode cur_priv);
      return case (cur_priv)
		m_Priv_Mode: (rg_dcsr [15] == 1'b1);
		s_Priv_Mode: (rg_dcsr [13] == 1'b1);
		u_Priv_Mode: (rg_dcsr [12] == 1'b1);
	     endcase;
   endmethod

   // Read dcsr.step
   method Bool read_dcsr_step ();
      return unpack (rg_dcsr [2]);
   endmethod

   // Update 'cause' in DCSR
   method Action write_dcsr_cause (DCSR_Cause cause);
      Bit #(3) b3 = pack (cause);
      rg_dcsr <= { rg_dcsr [31:9], b3, rg_dcsr [5:0] };
   endmethod

   method WordXL watchpoint_hit (WordXL addr);
      return ((addr == rg_watchpoint1) ? 1 : 0);
   endmethod

   method Action set_watch_n (WordXL  n);
      rg_watch_n <= n;
   endmethod

`endif

endmodule

// ================================================================

endpackage