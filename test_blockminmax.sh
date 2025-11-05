#!/usr/bin/env bash
set -euo pipefail

# Unit test for blockminmax
# - Exercises three modes on a tiny dataset:
#   1) Default (llround + clamp), with --tclfmt for stable text
#   2) Tcl-like (--tclround --tclfmt)
#   3) GMT-like (--gmtbin)
# - Compares against a reference answer after sorting rows.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BIN=./blockminmax
if [[ ! -x "$BIN" ]]; then
  echo "Building blockminmax ..." >&2
  make >/dev/null
fi

# Construct a tiny dataset that highlights differences:
# - A: out-of-bounds near (0,0) with low z -> default/tcllike clamp it into (0,0); gmtbin drops it
# - B: exact 0.5 tie -> default (half-away) goes to (1,1); tcllike/gmtbin go to (0,0)
# - C: interior point at (2,2)
# - D: point near (1,0)
cat > testdata_small.xyz << 'EOF'
-0.49 -0.49 5
0.5   0.5   10
2.0   2.0   9
1.49  0.49  7
EOF

REG="-R0/2/0/2"
INC="-I1"
INP="testdata_small.xyz"

rm -f out_default.min out_tcllike.min out_gmt.min

# 1) Default mode (llround + clamp); use native formatting (no --tclfmt)
"$BIN" $REG $INC -PATH "$INP" -o out_default.min >/dev/null

# 2) Tcl-like rounding/formatting
"$BIN" $REG $INC -PATH "$INP" --tclround --tclfmt -o out_tcllike.min >/dev/null

# 3) GMT-like binning (gridline registration); prints x,y as %.1f and z numeric
"$BIN" $REG $INC -PATH "$INP" --gmtbin -o out_gmt.min >/dev/null

# References per mode
cat > ref_default.min << 'EOF'
0 0 5
1 0 7
1 1 10
2 2 9
EOF

cat > ref_tcllike.min << 'EOF'
0.0 0.0 5
1.0 0.0 7
2.0 2.0 9
EOF

cat > ref_gmt.min << 'EOF'
0.0 0.0 5
1.0 0.0 7
2.0 2.0 9
EOF

# Compare after sort
LC_ALL=C sort ref_default.min > ref_default.sorted
LC_ALL=C sort ref_tcllike.min > ref_tcllike.sorted
LC_ALL=C sort ref_gmt.min > ref_gmt.sorted
LC_ALL=C sort out_default.min > out_default.sorted
LC_ALL=C sort out_tcllike.min > out_tcllike.sorted
LC_ALL=C sort out_gmt.min > out_gmt.sorted

diff -u ref_default.sorted out_default.sorted >/dev/null && echo "PASS default" || { echo "FAIL default"; diff -u ref_default.sorted out_default.sorted || true; exit 1; }
diff -u ref_tcllike.sorted out_tcllike.sorted >/dev/null && echo "PASS tcllike" || { echo "FAIL tcllike"; diff -u ref_tcllike.sorted out_tcllike.sorted || true; exit 1; }
diff -u ref_gmt.sorted out_gmt.sorted >/dev/null && echo "PASS gmtbin" || { echo "FAIL gmtbin"; diff -u ref_gmt.sorted out_gmt.sorted || true; exit 1; }

echo "All tests passed"
