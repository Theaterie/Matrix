#!/usr/bin/env python3
"""
Golden reference model for the weight-stationary systolic array.

Models the exact computation:
  C[M×N] += A[M×K] × B[K×N]

with tiled execution matching the RTL architecture:
  - PE array: ROWS × COLS
  - Weights: B matrix, preloaded into PEs (weight-stationary)
  - Activations: A matrix, streamed through array K_DEPTH cycles at a time
  - Results: C matrix, accumulated across K tiles

Usage:
  python golden_model.py                  # Run built-in self-test
  python golden_model.py --compare FILE   # Compare against RTL output file
  python golden_model.py --generate       # Generate test vectors (A, B, expected C)
"""

import numpy as np
import argparse
import sys
import os
from dataclasses import dataclass
from typing import Tuple, List, Optional


@dataclass
class SystolicConfig:
    """Hardware configuration matching RTL parameters."""
    rows: int = 16       # PE array rows (= K tile size)
    cols: int = 16       # PE array columns (= N tile size)
    k_depth: int = 16    # Activations per tile
    data_width: int = 16
    accum_width: int = 40


def systolic_golden(
    A: np.ndarray,  # [M, K]
    B: np.ndarray,  # [K, N]
    config: SystolicConfig,
) -> np.ndarray:
    """
    Compute C = A @ B matching the RTL systolic array behavior.

    RTL computation (for one invocation with weights W[ROWS][COLS]
    and activations loaded as A_hw[ROWS][K_DEPTH] in row-major BRAM order):

      PE(r,c) accumulates: sum_{k=0}^{K_DEPTH-1} W[r][c] * A_hw[r][k]
      Column result[c]:    sum_{r=0}^{ROWS-1} PE(r,c)

    Overall: result[c] = sum_r sum_k W[r][c] * A_hw[r][k]

    For standard matmul C = A[M×K] × B[K×N]:
      - K-reduction requires a DIFFERENT weight per K-index
      - Hardware is weight-stationary: each PE holds ONE weight (pe.sv weight_r)
      - So only ROWS different K-indices can be reduced per tile (one per PE row)
      - K_DEPTH does NOT extend the K-reduction; it reuses the same weight
        across K_DEPTH activation cycles
      - For standard matmul, only A_hw[r][0] is filled; A_hw[r][1..K_DEPTH-1] = 0
      - Result is identical regardless of K_DEPTH (1 or >1)

    Mapping:
      - TILE_K = ROWS (K-indices per tile, one per PE row)
      - TILE_N = COLS (N-indices per tile)
      - W[r][c] = B[k_start+r][n_start+c]
      - A_hw[r][0] = A[m][k_start+r],  A_hw[r][1..K_DEPTH-1] = 0
      - Result[c] = sum_r B[k+r][n+c] * A[m][k+r] = partial_C at tile (k,n)

    Each systolic_array invocation handles ONE K-tile (ROWS indices of K)
    and ONE N-tile (COLS indices of N), producing ONE row (m) of partial output.
    """
    M, K = A.shape
    Kb, N = B.shape
    assert K == Kb, f"Dimension mismatch: A is M×{K}, B is {Kb}×{N}"

    TILE_K = config.rows     # K indices per tile (= ROWS)
    TILE_N = config.cols     # N indices per tile (= COLS)

    C = np.zeros((M, N), dtype=np.int64)

    for m in range(M):
        for n_start in range(0, N, TILE_N):
            n_end = min(n_start + TILE_N, N)
            acc = np.zeros(n_end - n_start, dtype=np.int64)

            for k_start in range(0, K, TILE_K):
                k_end = min(k_start + TILE_K, K)

                # Weight tile: W[r][c] = B[k_start+r][n_start+c]
                W = B[k_start:k_end, n_start:n_end]  # [k_len, n_len]

                # Activation vector: A_hw[r][0] = A[m][k_start+r]
                # K_DEPTH is irrelevant for standard matmul because weights are
                # stationary — each PE uses one weight for all K_DEPTH cycles,
                # so only one activation per PE row contributes (slot 0).
                a_vec = A[m, k_start:k_end]  # [k_len]

                # result[c] = sum_r W[r][c] * a_vec[r]
                result = W.T @ a_vec  # [n_len]

                acc += result

            C[m, n_start:n_end] = acc

    return C


def compute_pe_accumulation(
    W: np.ndarray,  # [ROWS, COLS] weights
    A: np.ndarray,  # [ROWS, K_DEPTH] activations
) -> np.ndarray:
    """
    Model per-PE accumulation with vertical summation.
    PE(r,c) accumulates: sum_k W[r,c] * A[r,k]
    Column result: sum_r PE(r,c)

    Returns: [COLS] final column results.
    """
    rows, cols = W.shape
    r_rows, k_depth = A.shape
    assert rows == r_rows, "Weight and activation row counts must match"

    # Per-PE accumulation (each PE independently)
    pe_acc = np.zeros((rows, cols), dtype=np.int64)
    for r in range(rows):
        for c in range(cols):
            pe_acc[r, c] = np.sum(W[r, c] * A[r, :])

    # Vertical sum (all PE rows contribute to each column)
    result = np.sum(pe_acc, axis=0)  # [COLS]

    return result


def compute_result_serializer_output(
    W: np.ndarray,  # [ROWS, COLS] weights
    A: np.ndarray,  # [ROWS, K_DEPTH] activations
) -> np.ndarray:
    """
    Model the result_serializer capture order.

    During READOUT, results appear row-by-row as the pipeline drains.
    Capture t (0-indexed, 0..ROWS-1) contains the vertical sum of PE rows 0..t:
      capture[t][c] = sum_{r=0}^{t} sum_{k} W[r,c] * A[r,k]

    Serialized in row-major order:
      BRAM[t*COLS + c] = capture[t][c]

    Returns: [ROWS, COLS] — all captured results.
    """
    rows, cols = W.shape
    r_rows, k_depth = A.shape
    assert rows == r_rows

    pe_acc = np.zeros((rows, cols), dtype=np.int64)
    for r in range(rows):
        for c in range(cols):
            pe_acc[r, c] = int(np.sum(np.int64(W[r, c]) * np.int64(A[r, :])))

    # Cumulative sum from top to bottom
    captures = np.cumsum(pe_acc, axis=0)  # [ROWS, COLS]

    return captures


def generate_test_vectors(
    M: int, N: int, K: int, config: SystolicConfig, seed: int = 42
) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """
    Generate random test matrices A[M×K], B[K×N] and compute golden C[M×N].
    Values are within INT16 range for RTL compatibility.
    """
    rng = np.random.RandomState(seed)

    # Generate values in [-128, 127] range (safe for INT16 accumulation)
    A = rng.randint(-128, 128, (M, K), dtype=np.int64)
    B = rng.randint(-128, 128, (K, N), dtype=np.int64)

    C = systolic_golden(A, B, config)

    return A, B, C


def format_for_rtl_tb(
    A: np.ndarray, B: np.ndarray, config: SystolicConfig, m: int, n_start: int, k_start: int
) -> str:
    """
    Format A and B tiles for direct use in RTL testbench (SystemVerilog array literals).
    """
    TILE_K = config.rows
    TILE_N = config.cols

    k_end = min(k_start + TILE_K, A.shape[1])
    n_end = min(n_start + TILE_N, B.shape[1])

    A_tile = A[m, k_start:k_end]
    B_tile = B[k_start:k_end, n_start:n_end]

    lines = []
    lines.append(f"  // Tile: m={m}, n={n_start}, k={k_start}")
    lines.append(f"  // A_tile = {A_tile.tolist()}")
    lines.append(f"  // B_tile:")

    for r in range(B_tile.shape[0]):
        lines.append(f"  //   row {r}: {B_tile[r].tolist()}")

    return "\n".join(lines)


def compare_with_rtl_output(
    rtl_output_file: str, golden: np.ndarray, tolerance: int = 0
) -> bool:
    """
    Compare RTL simulation output against golden model.

    Expected file format: one result per line:
      <row> <col> <value>
    or CSV:
      row,col,value

    Returns True if all values match within tolerance.
    """
    rtl_results = {}
    with open(rtl_output_file, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or line.startswith('//'):
                continue
            parts = line.replace(',', ' ').split()
            if len(parts) >= 3:
                row, col, val = int(parts[0]), int(parts[1]), int(parts[2])
                rtl_results[(row, col)] = val

    mismatches = []
    for m in range(golden.shape[0]):
        for n in range(golden.shape[1]):
            golden_val = int(golden[m, n])
            rtl_val = rtl_results.get((m, n))
            if rtl_val is None:
                mismatches.append(f"  Missing RTL result for ({m},{n})")
            elif abs(rtl_val - golden_val) > tolerance:
                mismatches.append(
                    f"  Mismatch ({m},{n}): RTL={rtl_val}, Golden={golden_val}, "
                    f"diff={rtl_val - golden_val}"
                )

    if mismatches:
        print(f"FAIL: {len(mismatches)} mismatches found:")
        for m in mismatches[:20]:  # Limit output
            print(m)
        return False
    else:
        print(f"PASS: All {golden.shape[0] * golden.shape[1]} results match.")
        return True


def self_test():
    """Built-in self-test to verify the golden model."""
    config = SystolicConfig(rows=4, cols=4, k_depth=4)

    # Test 1: Identity B × all-ones A
    #   W = eye(4), A_hw[r] summed along K_DEPTH = 1 per row
    #   result[c] = sum_r W[r][c] * 1 = 1 for all c
    K_tile = 4
    A = np.ones((1, K_tile), dtype=np.int64)  # M=1, K=4, all 1's
    B = np.eye(K_tile, dtype=np.int64)         # K=4, N=4, identity

    C = systolic_golden(A, B, config)
    expected = np.ones((1, K_tile), dtype=np.int64)  # Each column = 1
    assert np.array_equal(C, expected), f"Test 1 failed: {C} != {expected}"
    print(f"  [PASS] Test 1: Identity B × all-ones A = {C[0]}")

    # Test 2: Sequential weights
    B2 = np.arange(1, 17, dtype=np.int64).reshape(4, 4)
    A2 = np.ones((1, 4), dtype=np.int64)
    C2 = systolic_golden(A2, B2, config)
    # Each column sum of B: col 0=1+5+9+13=28, col1=2+6+10+14=32, etc.
    expected2 = np.array([[28, 32, 36, 40]], dtype=np.int64)
    assert np.array_equal(C2, expected2), f"Test 2 failed: {C2} != {expected2}"
    print(f"  [PASS] Test 2: {B2[0]} × all-ones = {C2[0]}")

    # Test 3: K-tile accumulation (K=8 with 4×4 tiles → 2 K-tiles)
    config3 = SystolicConfig(rows=4, cols=4, k_depth=4)
    A3 = np.ones((1, 8), dtype=np.int64)
    B3 = np.ones((8, 4), dtype=np.int64)
    C3 = systolic_golden(A3, B3, config3)
    expected3 = np.ones((1, 4), dtype=np.int64) * 8  # 1*1 added 8 times per col
    print(f"  C3 = {C3}")
    assert np.array_equal(C3, expected3), f"Test 3 failed: {C3} != {expected3}"
    print(f"  [PASS] Test 3: K=8, 2 tiles: result = {C3[0]}")

    # Test 4: Multiple output rows (M=3)
    A4 = np.array([
        [1, 0, 0, 0],
        [0, 2, 0, 0],
        [0, 0, 3, 0],
    ], dtype=np.int64)
    B4 = np.eye(4, dtype=np.int64)
    C4 = systolic_golden(A4, B4, config)
    expected4 = np.array([
        [1, 0, 0, 0],
        [0, 2, 0, 0],
        [0, 0, 3, 0],
    ], dtype=np.int64)
    assert np.array_equal(C4, expected4), f"Test 4 failed:\n{C4}\n!=\n{expected4}"
    print(f"  [PASS] Test 4: M=3, K=4, N=4: C =\n{C4}")

    # Test 5: N-tile iteration (N=8 with 4×4 tiles, K_DEPTH=1 mode)
    #   A = [1,1,1,1], B = [eye(4) | 2*eye(4)]
    #   K_DEPTH=1 → each PE row sees exactly one A value
    #   result[c] = sum_r B[r][c] * A[0][r]
    config5 = SystolicConfig(rows=4, cols=4, k_depth=1)
    A5 = np.ones((1, 4), dtype=np.int64)
    B5 = np.hstack([np.eye(4, dtype=np.int64), np.eye(4, dtype=np.int64) * 2])
    C5 = systolic_golden(A5, B5, config5)
    # identity: result=[1,1,1,1]; 2*identity: result=[2,2,2,2]
    expected5 = np.array([[1, 1, 1, 1, 2, 2, 2, 2]], dtype=np.int64)
    assert np.array_equal(C5, expected5), f"Test 5 failed:\n{C5}\n!=\n{expected5}"
    print(f"  [PASS] Test 5: N=8, 2 tiles (K_DEPTH=1): C = {C5[0]}")

    # Test 6: Full M×N×K = 4×6×12 with K_DEPTH=1 (standard matmul)
    #   TILE_K=4, TILE_N=4, K=12 → 3 K-tiles per output element
    config6 = SystolicConfig(rows=4, cols=4, k_depth=1)
    A6, B6, C6 = generate_test_vectors(4, 6, 12, config6, seed=123)
    C6_direct = A6 @ B6
    assert np.array_equal(C6, C6_direct), (
        f"Test 6 failed: tiled != direct\n{C6}\n!=\n{C6_direct}"
    )
    print(f"  [PASS] Test 6: 4×6×12 tiled matches direct matmul (K_DEPTH=1)")

    # Test 7: PE accumulation + result serializer model (K_DEPTH=4 mode)
    W7 = np.arange(1, 17, dtype=np.int64).reshape(4, 4)
    A7 = np.ones((4, 4), dtype=np.int64)  # All 1's: each PE row sums to 4
    result7 = compute_pe_accumulation(W7, A7)
    # PE(r,c) accumulates: W7[r][c] * 4
    # Column result: sum_r W7[r][c] * 4 = 4 * column_sum
    expected7 = 4 * np.sum(W7, axis=0)
    assert np.array_equal(result7, expected7), f"Test 7 failed: {result7} != {expected7}"
    print(f"  [PASS] Test 7: PE accumulation result = {result7} (4× column sums)")

    # Test 8: Result serializer capture order
    captures = compute_result_serializer_output(W7, A7)
    # Row 0: PE(0,c) only → W7[0][c] * 4 = [4, 8, 12, 16]
    # Row 0+1: W7[0][c]*4 + W7[1][c]*4 = [24, 32, 40, 48]
    # etc.
    expected_cap0 = 4 * W7[0]   # [4, 8, 12, 16]
    assert np.array_equal(captures[0], expected_cap0), f"Capture 0 mismatch"
    print(f"  [PASS] Test 8: Result serializer captures row 0 = {captures[0]}")

    # Test 9: K_DEPTH invariance — standard matmul result is independent of K_DEPTH
    #   Weights are stationary (pe.sv weight_r), so K_DEPTH>1 cannot extend
    #   K-reduction. Only slot 0 is used; result equals K_DEPTH=1.
    config_k1 = SystolicConfig(rows=4, cols=4, k_depth=1)
    config_k4 = SystolicConfig(rows=4, cols=4, k_depth=4)
    config_k16 = SystolicConfig(rows=4, cols=4, k_depth=16)
    A9 = np.random.RandomState(99).randint(-50, 50, (3, 8))
    B9 = np.random.RandomState(88).randint(-50, 50, (8, 5))
    C_k1 = systolic_golden(A9, B9, config_k1)
    C_k4 = systolic_golden(A9, B9, config_k4)
    C_k16 = systolic_golden(A9, B9, config_k16)
    C_direct = A9 @ B9
    assert np.array_equal(C_k1, C_direct), "K_DEPTH=1 mismatch vs direct"
    assert np.array_equal(C_k4, C_k1), "K_DEPTH=4 differs from K_DEPTH=1"
    assert np.array_equal(C_k16, C_k1), "K_DEPTH=16 differs from K_DEPTH=1"
    print(f"  [PASS] Test 9: K_DEPTH invariance (1 == 4 == 16, all match A@B)")

    print("\n  All golden model self-tests passed!")


def main():
    parser = argparse.ArgumentParser(
        description="Golden reference model for systolic array matrix multiplier"
    )
    parser.add_argument(
        "--compare", type=str, metavar="FILE",
        help="Compare golden model against RTL output file"
    )
    parser.add_argument(
        "--generate", action="store_true",
        help="Generate test vectors for RTL testbench"
    )
    parser.add_argument(
        "--M", type=int, default=4, help="Output rows (default: 4)"
    )
    parser.add_argument(
        "--N", type=int, default=4, help="Output columns (default: 4)"
    )
    parser.add_argument(
        "--K", type=int, default=4, help="Common dimension (default: 4)"
    )
    parser.add_argument(
        "--rows", type=int, default=4, help="PE rows / K tile size (default: 4)"
    )
    parser.add_argument(
        "--cols", type=int, default=4, help="PE cols / N tile size (default: 4)"
    )
    parser.add_argument(
        "--k-depth", type=int, default=1,
        help="K_DEPTH (activations per PE; does not affect standard matmul, default: 1)"
    )
    parser.add_argument(
        "--seed", type=int, default=42, help="Random seed (default: 42)"
    )
    parser.add_argument(
        "--self-test", action="store_true", default=True,
        help="Run built-in self-tests"
    )
    args = parser.parse_args()

    config = SystolicConfig(rows=args.rows, cols=args.cols, k_depth=args.k_depth)

    if args.self_test and not args.compare:
        print("=== Golden Model Self-Test ===")
        self_test()

    if args.generate:
        print(f"\n=== Generating Test Vectors ({args.M}×{args.N}×{args.K}) ===")
        A, B, C = generate_test_vectors(args.M, args.N, args.K, config, args.seed)

        print(f"A ({args.M}×{args.K}):")
        print(A)
        print(f"\nB ({args.K}×{args.N}):")
        print(B)
        print(f"\nC = A × B ({args.M}×{args.N}):")
        print(C)

        # Compute max absolute value to verify it fits in accumulator
        max_val = np.max(np.abs(C))
        print(f"\nMax |value| = {max_val}")
        print(f"Accum width needed: {int(np.ceil(np.log2(max_val + 1)))} bits")

        # Save to files
        out_dir = "test_vectors"
        os.makedirs(out_dir, exist_ok=True)
        np.savetxt(f"{out_dir}/A.txt", A, fmt="%d")
        np.savetxt(f"{out_dir}/B.txt", B, fmt="%d")
        np.savetxt(f"{out_dir}/C_golden.txt", C, fmt="%d")
        print(f"\nTest vectors saved to {out_dir}/")

    if args.compare:
        print(f"\n=== Comparing RTL output: {args.compare} ===")
        # Need matrices to compare against — load from files or generate
        A_file = "test_vectors/A.txt"
        B_file = "test_vectors/B.txt"
        if os.path.exists(A_file) and os.path.exists(B_file):
            A = np.loadtxt(A_file, dtype=np.int64)
            B = np.loadtxt(B_file, dtype=np.int64)
            C = systolic_golden(A, B, config)
            compare_with_rtl_output(args.compare, C)
        else:
            print("ERROR: Need A.txt and B.txt in test_vectors/ for comparison.")
            print("Run with --generate first to create test vectors.")


if __name__ == "__main__":
    main()
