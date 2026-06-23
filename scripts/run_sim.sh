#!/bin/bash
#==============================================================================
# run_sim.sh  —  One-click MAC unit simulation
# Usage: bash scripts/run_sim.sh
#==============================================================================

# Adjust this to your Vivado install path if not in PATH
VIVADO_BIN="D:/2025.2/Vivado/bin/vivado.bat"

echo "============================================================"
echo "  Matrix MAC Unit — Behavioral Simulation"
echo "============================================================"

cd "$(dirname "$0")/.."

if command -v vivado &> /dev/null; then
    vivado -mode batch -source scripts/sim_mac.tcl -notrace
elif [ -f "$VIVADO_BIN" ]; then
    "$VIVADO_BIN" -mode batch -source scripts/sim_mac.tcl -notrace
else
    echo ""
    echo "[ERROR] vivado command not found"
    echo "Add Vivado bin/ to PATH, or edit VIVADO_BIN in this script"
    echo "Example: export PATH=\"\$PATH:/d/2025.2/Vivado/bin\""
    exit 1
fi
