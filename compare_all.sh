#!/usr/bin/env bash
set -euo pipefail

# Compare min-per-cell results produced by:
#  - Tcl:   blockminmax.tcl (with -FIXMIN -TIELOW)
#  - C:     blockminmax (with --tclround --tclfmt)
#  - GMT:   blockmedian (with -E and printing column 5 = min)
#
# Then visualize each as a green-shaded PNG using a common color scale and open them (macOS).
#
# Usage:
#   ./compare_all.sh -R xmin/xmax/ymin/ymax -I inc -P path/to/test.xyz [--no-open]
#
# Outputs:
#   - tcl.min, c.min, gmt.min            (unsorted xyz)
#   - tcl.sorted, c.sorted, gmt.sorted   (sorted xyz)
#   - tcl.png, c.png, gmt.png            (visualizations)

RVAL=""
INC=""
PATH_XYZ=""
NO_OPEN=0

die(){ echo "Error: $*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    -R*) RVAL="${1#-R}"; shift ;;
    -I)  INC="${2:-}"; shift 2 ;;
    -I*) INC="${1#-I}"; shift ;;
    -P)  PATH_XYZ="${2:-}"; shift 2 ;;
    -P*) PATH_XYZ="${1#-P}"; shift ;;
    --no-open) NO_OPEN=1; shift ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[[ -n "$RVAL" ]] || die "Missing -R xmin/xmax/ymin/ymax"
[[ -n "$INC"  ]] || die "Missing -I inc"
[[ -n "$PATH_XYZ" && -f "$PATH_XYZ" ]] || die "Missing -P path/to/xyz or file not found"

echo "Input: $PATH_XYZ"
echo "Region: -R$RVAL"
echo "Inc: -I$INC"

command -v tclsh >/dev/null 2>&1 || die "tclsh not found"
command -v gmt   >/dev/null 2>&1 || die "GMT (gmt) not found"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# 1) Tcl
rm -f tcl.min
echo "[1/6] Tcl: blockminmax.tcl ..." >&2
tclsh ./blockminmax.tcl -R"$RVAL" -I"$INC" -PATH "$PATH_XYZ" -FIXMIN -TIELOW >/dev/null
mv -f "${PATH_XYZ}.min" tcl.min

# 2) C
rm -f c.min
echo "[2/6] C: blockminmax ..." >&2
if [[ ! -x ./blockminmax ]]; then die "./blockminmax not found; build it first (make -C other)"; fi
./blockminmax -R"$RVAL" -I"$INC" -PATH "$PATH_XYZ" --tclround --tclfmt -o c.min >/dev/null

# 3) GMT blockmedian (table output, min in column 5)
rm -f gmt.min
echo "[3/6] GMT: blockmedian ..." >&2
gmt blockmedian "$PATH_XYZ" -R"$RVAL" -I"$INC" -E -C | awk '{printf("%.1f %.1f %s\n", $1, $2, $5)}' > gmt.min

# 4) Sort and compare
echo "[4/6] Sorting and comparing ..." >&2
LC_ALL=C sort tcl.min > tcl.sorted
LC_ALL=C sort c.min   > c.sorted
LC_ALL=C sort gmt.min > gmt.sorted

cmp -s tcl.sorted c.sorted && echo "Tcl vs C: IDENTICAL" || echo "Tcl vs C: DIFFER" 
cmp -s tcl.sorted gmt.sorted && echo "Tcl vs GMT: IDENTICAL" || echo "Tcl vs GMT: DIFFER" 
cmp -s c.sorted   gmt.sorted && echo "C vs GMT: IDENTICAL"   || echo "C vs GMT: DIFFER" 

echo "Counts (lines):"
printf "  tcl.sorted: %9d\n" "$(wc -l < tcl.sorted)"
printf "  c.sorted:   %9d\n" "$(wc -l < c.sorted)"
printf "  gmt.sorted: %9d\n" "$(wc -l < gmt.sorted)"

# 5) Visualization (common color scale)
echo "[5/6] Visualizing with GMT ..." >&2
# Compute common z-range across all outputs
read -r ZMIN ZMAX < <(awk 'NR==1{min=$3; max=$3} {if($3<min)min=$3; if($3>max)max=$3} END{printf "%.10g %.10g\n",min,max}' tcl.min c.min gmt.min)
echo "Common z range: $ZMIN to $ZMAX" >&2

# Build a simple green-scale CPT (white -> green)
gmt makecpt -Cwhite,green -T${ZMIN}/${ZMAX} > common.cpt

vis() {
  local in_xyz=$1; local base=$2
  local grid=${base}.grd ps=${base}.ps png=${base}.png
  gmt xyz2grd "$in_xyz" -R"$RVAL" -I"$INC" -G"$grid" >/dev/null
  gmt grdimage "$grid" -R"$RVAL" -JX15c -Ccommon.cpt -Baf -P > "$ps"
  gmt psconvert -A -Tg -E200 -P -F"$base" "$ps" >/dev/null
  rm -f "$ps" "$grid"
}

vis tcl.min tcl
vis c.min   c
vis gmt.min gmt

# 6) Open images (macOS)
echo "[6/6] Opening images ..." >&2
if command -v open >/dev/null 2>&1 && [[ "$NO_OPEN" -eq 0 ]]; then
  open tcl.png c.png gmt.png || true
else
  echo "open not available or suppressed; images: tcl.png c.png gmt.png" >&2
fi

echo "Done."
