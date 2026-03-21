#!/usr/bin/env python3
"""Kassadin vs Dolos verification suite."""
import subprocess, json, sys

print("=" * 60)
print("KASSADIN vs DOLOS VERIFICATION")
print("=" * 60)

passed = 0
failed = 0
pending = 0

# 1. Tip parity
print("\n--- Tip Parity ---")
r = subprocess.run(["./cardano-cli-native", "query", "tip", "--socket-path", "./kassadin.socket", "--testnet-magic", "1"], capture_output=True, text=True)
k_tip = json.loads(r.stdout) if r.returncode == 0 else None

r2 = subprocess.run(["./zig-out/bin/kassadin", "dolos-tip"], capture_output=True, text=True)
d_slot = None
for line in r2.stderr.split('\n'):
    if 'Slot:' in line: d_slot = int(line.split(':')[1].strip())

if k_tip and d_slot is not None:
    delta = abs(k_tip['slot'] - d_slot)
    print(f"  Kassadin: slot={k_tip['slot']} block={k_tip['block']}")
    print(f"  Dolos:    slot={d_slot}")
    if delta <= 100:
        print(f"  PASS (delta={delta})")
        passed += 1
    else:
        print(f"  FAIL (delta={delta})")
        failed += 1
else:
    print("  FAIL: could not query one or both nodes")
    failed += 1

# 2. Block count
print("\n--- Block Count ---")
if k_tip:
    bn = k_tip['block']
    print(f"  Block: {bn}")
    if 4_000_000 < bn < 5_000_000:
        print(f"  PASS")
        passed += 1
    else:
        print(f"  FAIL (outside range)")
        failed += 1

# 3. Pending items
print("\n--- Pending ---")
for item in ["UTxO spot-check (needs N2C GetUTxOByTxIn)", "Epoch rewards (next boundary)", "script_data_hash (needs cost models)"]:
    print(f"  PENDING: {item}")
    pending += 1

print(f"\n{'=' * 60}")
print(f"PASSED: {passed}  FAILED: {failed}  PENDING: {pending}")
sys.exit(1 if failed > 0 else 0)
