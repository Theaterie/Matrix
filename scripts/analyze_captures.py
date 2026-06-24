#!/usr/bin/env python3
"""
Analyze what the result_serializer captures by simulating the exact 
hardware pipeline timing (skew chains + MAC pipeline).
"""
import numpy as np

ROWS, COLS, K_DEPTH = 4, 4, 4

# Test case 1: identity weights, all-ones activations
W = np.eye(ROWS, COLS, dtype=np.int64)
A = np.ones((ROWS, K_DEPTH), dtype=np.int64)

print("=== Test case: Identity weights x All-ones activations ===")
print(f"W = eye({ROWS})")
print(f"A = ones({ROWS}x{K_DEPTH}) = every row has 4 ones")
print()

# Per-PE accumulation (full, unlimited): PE(r,c) = W[r][c] * sum_k A[r][k]
pe_full = np.zeros((ROWS, COLS), dtype=np.int64)
for r in range(ROWS):
    for c in range(COLS):
        pe_full[r, c] = W[r, c] * A[r, :].sum()

print("Per-PE full accumulation (all K_DEPTH activations):")
print(pe_full)
print()

# Golden model (as written in testbench)
def golden_capture(t, c):
    """Capture t = cumulative sum of PE rows 0..t"""
    return pe_full[:t+1, c].sum()

print("Golden model captures (cumulative rows):")
for t in range(ROWS):
    for c in range(COLS):
        val = golden_capture(t, c)
        print(f"  capture[{t}][{c}] = {val:3d}  (sum rows 0..{t})")

print()

# ===============================================================
# Hardware pipeline simulation
# ===============================================================
# 
# Architecture summary:
# - Row r has 2*r cycles skew (shift register)
# - Each PE: 2-cycle MAC pipeline (S1=mult, S2=accumulate)
# - Act propagates left->right: 2 cycles/PE (registered)
# - Psum propagates top->bottom: 2 cycles/PE (through MAC)
#
# During COMPUTE (K_DEPTH=4 cycles):
#   deser outputs act[r][k] at cycle k for all rows
#   But row r sees it after 2*r skew cycles
#
# During READOUT (2*(ROWS+COLS)=16 cycles):
#   Pipeline continues draining
#   result_serializer captures when result_valid & cap_row < ROWS

def sim_hardware_pipeline(W, A, ROWS, COLS, K_DEPTH):
    """
    Simulate the exact hardware pipeline including skew chains
    and MAC 2-stage pipeline, tracking psum propagation.
    """
    # State
    # Skew chains: shift_regs[r] has depth 2*r
    skew_regs = [np.zeros(2*r, dtype=np.int64) for r in range(ROWS)]
    skew_valid = [np.zeros(2*r, dtype=bool) for r in range(ROWS)]
    
    # Activation network: act_net[r][c] = activation at PE(r,c) input
    act_net = np.zeros((ROWS, COLS), dtype=np.int64)
    act_valid = np.zeros((ROWS, COLS), dtype=bool)
    
    # MAC stage 1: product registers
    mac_s1_prod = np.zeros((ROWS, COLS), dtype=np.int64)
    mac_s1_valid = np.zeros((ROWS, COLS), dtype=bool)
    mac_s1_acc_in = np.zeros((ROWS, COLS), dtype=np.int64)  # psum_in captured
    mac_s1_clear = np.zeros((ROWS, COLS), dtype=bool)
    
    # MAC stage 2: accumulator output
    mac_s2_acc = np.zeros((ROWS, COLS), dtype=np.int64)  # acc_out
    mac_s2_valid = np.zeros((ROWS, COLS), dtype=bool)
    
    # Psum network: psum[r][c] = psum at output of PE(r-1,c)
    psum = np.zeros((ROWS+1, COLS), dtype=np.int64)
    
    # Result serializer
    cap_buf = []  # list of captured row vectors
    cap_active = True  # cap_row < ROWS
    
    total_cycles = K_DEPTH + 2 * (ROWS + COLS) + 10  # extra margin
    
    print("Cycle-by-cycle simulation:")
    print(f"{'Cycle':>5} {'Phase':>10} {'act_in[0]':>8} {'act_in[1]':>8} {'act_in[2]':>8} {'act_in[3]':>8} | {'bottom_ps[0]':>12} {'bottom_ps[1]':>12} {'bottom_ps[2]':>12} {'bottom_ps[3]':>12} | cap_row")
    print("-"*100)
    
    for cycle in range(total_cycles):
        phase = "COMPUTE" if cycle < K_DEPTH else "READOUT"
        
        # ---- Step 1: Deserializer output ----
        if cycle < K_DEPTH:
            k = cycle
            deser_out = A[:, k]  # [ROWS] activation vector
            deser_valid = True
        else:
            deser_out = np.zeros(ROWS, dtype=np.int64)
            deser_valid = False
        
        # ---- Step 2: Skew chains shift ----
        act_skewed = np.zeros(ROWS, dtype=np.int64)
        valid_skewed = np.zeros(ROWS, dtype=bool)
        
        for r in range(ROWS):
            if 2*r == 0:
                act_skewed[r] = deser_out[r]
                valid_skewed[r] = deser_valid
            else:
                # Shift register of depth 2*r
                # Output is last stage
                out_val = skew_regs[r][-1]
                out_vald = skew_valid[r][-1]
                act_skewed[r] = out_val
                valid_skewed[r] = out_vald
                # Shift in
                if 2*r > 1:
                    skew_regs[r] = np.roll(skew_regs[r], 1)
                    skew_regs[r][0] = deser_out[r]
                    skew_valid[r] = np.roll(skew_valid[r], 1)
                    skew_valid[r][0] = deser_valid
                elif 2*r == 1:
                    skew_regs[r][0] = deser_out[r]
                    skew_valid[r][0] = deser_valid
        
        # ---- Step 3: Set left boundary ----
        act_in_pe = np.zeros((ROWS, COLS), dtype=np.int64)
        valid_in_pe = np.zeros((ROWS, COLS), dtype=bool)
        act_in_pe[:, 0] = act_skewed
        valid_in_pe[:, 0] = valid_skewed
        
        # ---- Step 4: Act propagation update (pass-through from prev col) ----
        # act_net[r][c] = activation entering PE(r,c) from left
        # Need to model: act_out of PE(r,c-1) becomes act_in of PE(r,c)
        # Each PE delays act by 2 cycles (act_d2)
        # For simplicity in a cycle-accurate sim, we propagate one cycle at a time.
        # act_in_PE = act_skewed at left boundary
        # Inside PE: act_d1 <= act_in, act_d2 <= act_d1, act_out = act_d2
        # So act_out = act_in delayed by 2 cycles
        # We'll simulate this cycle by cycle
        
        # ---- Step 5: MAC pipeline (all PEs) ----
        # S2 executes using S1 values from previous cycle
        for r in range(ROWS):
            for c in range(COLS):
                if mac_s1_valid[r, c]:
                    if mac_s1_clear[r, c]:
                        mac_s2_acc[r, c] = mac_s1_prod[r, c]
                    else:
                        mac_s2_acc[r, c] = mac_s1_acc_in[r, c] + mac_s1_prod[r, c]
                    mac_s2_valid[r, c] = True
                else:
                    mac_s2_valid[r, c] = False
        
        # ---- Step 6: Update psum network (S2 output feeds down) ----
        # psum[r+1][c] gets mac_s2_acc of PE(r,c)
        for r in range(ROWS):
            for c in range(COLS):
                if mac_s2_valid[r, c]:
                    psum[r+1, c] = mac_s2_acc[r, c]
                # psum stays if not valid (hold)
        
        # Bottom edge
        bottom_ps = psum[ROWS, :]
        
        # ---- Step 7: Capture at bottom edge if valid ----
        # result_valid = psum_valid_net[ROWS][COLS-1]
        psum_bottom_valid = mac_s2_valid[ROWS-1, COLS-1]
        if psum_bottom_valid and cap_active and len(cap_buf) < ROWS:
            cap_buf.append(bottom_ps.copy())
        
        # ---- Step 8: S1 captures new inputs ----
        # In hardware, act_net[r][c] = act_in to PE(r,c) at this cycle.
        # But act_net changes as act propagates. We need to model the PEs
        # properly with their 2-cycle act delay.
        
        # The act_in to PE(r,c) comes from act_out of PE(r,c-1)
        # We use act_net array to track this
        
        for r in range(ROWS):
            for c in range(COLS):
                # Current activation input to this PE
                a_val = act_in_pe[r, c] if c == 0 else act_net[r, c-1]
                a_vld = valid_in_pe[r, c] if c == 0 else act_valid[r, c-1]
                
                # S1 captures product
                mac_s1_prod[r, c] = W[r, c] * a_val
                mac_s1_acc_in[r, c] = psum[r, c]
                mac_s1_valid[r, c] = a_vld
                mac_s1_clear[r, c] = (cycle == 0)
                
                # Act propagates through this PE (simplified: 1 cycle latency)
                # Actually PE has 2-cycle act delay, so we track act_in flags
                # For accurate modeling, we'll use pipelined approach
        
        # For act propagation: each PE registers act_in then outputs after 2 cycles
        # We need a 2-deep shift register per PE for act
        # Let's store act values that will become available at output
        # We'll handle this with act_pipe[r][c][0] = act_in, act_pipe[r][c][1] = act_out
        
        # Update act_net for next cycle
        # New act_net = (previous cycle's act_in to PEs col 0..COLS-2 shifted right)
        new_act_net = np.zeros((ROWS, COLS), dtype=np.int64)
        new_act_valid = np.zeros((ROWS, COLS), dtype=bool)
        
        # Actually, each PE takes 2 cycles: act_d1 <= act_in, then act_d2 <= act_d1
        # So from PE(r,c-1)'s perspective, act enters at T, exits at T+2
        # We need to maintain a 2-deep buffer per column
        
        if not hasattr(sim_hardware_pipeline, 'act_pipe'):
            sim_hardware_pipeline.act_pipe = np.zeros((ROWS, COLS, 2), dtype=np.int64)
            sim_hardware_pipeline.act_pipe_valid = np.zeros((ROWS, COLS, 2), dtype=bool)
        
        act_pipe = sim_hardware_pipeline.act_pipe
        act_pipe_v = sim_hardware_pipeline.act_pipe_valid
        
        for r in range(ROWS):
            for c in range(COLS):
                # Shift pipe: stage1 gets act_in, stage2 gets stage1
                a_val = act_in_pe[r, c] if c == 0 else act_pipe[r, c-1, 1]
                a_vld = valid_in_pe[r, c] if c == 0 else act_pipe_v[r, c-1, 1]
                
                act_pipe[r, c, 1] = act_pipe[r, c, 0]  # stage1 -> stage2
                act_pipe[r, c, 0] = a_val
                act_pipe_v[r, c, 1] = act_pipe_v[r, c, 0]
                act_pipe_v[r, c, 0] = a_vld
                
                # Output to next column
                new_act_net[r, c] = act_pipe[r, c, 1]  # act_out = stage2
                new_act_valid[r, c] = act_pipe_v[r, c, 1]
        
        act_net = new_act_net
        act_valid = new_act_valid
        
        # Print progress every few cycles
        if cycle < 15 or (cycle % 5 == 0):
            print(f"{cycle:5d} {phase:>10} {act_skewed[0]:8d} {act_skewed[1]:8d} {act_skewed[2]:8d} {act_skewed[3]:8d} | {bottom_ps[0]:12d} {bottom_ps[1]:12d} {bottom_ps[2]:12d} {bottom_ps[3]:12d} | {len(cap_buf)}")
        
        # Stop early if not needed
        if len(cap_buf) >= ROWS and cycle > K_DEPTH + 2*(ROWS+COLS):
            break
    
    return np.array(cap_buf)

print("\n\nRunning cycle-accurate hardware pipeline simulation...")
hw_captures = sim_hardware_pipeline(W, A, ROWS, COLS, K_DEPTH)

print()
print(f"Hardware captured {len(hw_captures)} rows of results")
for t in range(min(len(hw_captures), ROWS)):
    print(f"  capture[{t}]: {hw_captures[t]}")

print()
print("Comparison with golden model:")
for t in range(min(len(hw_captures), ROWS)):
    for c in range(COLS):
        g = golden_capture(t, c)
        h = hw_captures[t, c]
        match = "OK" if g == h else "MISMATCH"
        print(f"  [{t},{c}] golden={g:3d}  hw={h:3d}  {match}")
