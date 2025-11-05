blockminmax: Tcl fixes, C port, and GMT parity
================================================

This folder contains:
- `blockminmax.tcl` — the original Tcl utility to compute the per‑cell minimum/maximum of XYZ data, with optional fixes and tie options added.
- `blockminmax.c` — a fast C implementation with additional modes to emulate Tcl and GMT behavior exactly.
- `Makefile` — builds the C binary with optimized defaults.
- `compare_all.sh` — runs Tcl, C (two modes), and GMT, normalizes output, compares, and visualizes results.

What changed in the Tcl version
- New option `-FIXMIN` (optional; off by default)
  - Fixes the “min” update logic so that in min mode a cell only accepts smaller `z`, and in max mode only larger `z`.
  - Original behavior overwrote with larger `z` as new points arrived, effectively keeping the last value seen.
- New tie option `-TIELOW` (alias: `-TIELOWER`) (optional; off by default)
  - When a point is exactly equidistant between two grid nodes, snap to the lower (smaller) node value.
- Notes
  - Tcl still writes output to `<input>.min` or `<input>.max` (no `-o` flag). Use `-MAX` to compute maxima.
  - The grid step respects `-I` where used to construct the grid list.
  - Without `-TIELOW`/`-TIELOWER` (the default), equidistant ties are not forced lower or higher; the script keeps the first candidate encountered by the search, which may not consistently favor lower or higher grid nodes. Use `-TIELOW` for deterministic, lower‑biased ties (to match the C `--tclround` mode).

How the C version was made
- Core behavior
  - Streams large XYZ files and bins to a regular grid (`-R`, `-I`).
  - Computes per‑cell min (default) or max (`-MAX`).
  - Writes only cells that received data.
  - Honors the increment precisely (no implicit 1.0 step).
- Options
  - `--tclround` — snap like Tcl’s nearest‑node with ties to the lower node (matches Tcl’s `-TIELOW`).
  - `--tclfmt` — format like Tcl: `x y` as `%.1f` and `z` as the original token string.
  - `--gmtbin` — emulate GMT 6.6.0 block binning exactly (gridline registration):
    - Grid node counts: `nx = round((xmax-xmin)/dx) + 1`, `ny = round((ymax-ymin)/dy) + 1`.
    - Column index: `col = lrint((x - xmin)/dx)`.
    - Row index: `row = ny - 1 - lrint((y - ymin)/dy)`.
    - Drop points that fall outside 0 ≤ row < ny, 0 ≤ col < nx.
    - Output node coordinates: `x = xmin + col*dx`, `y = ymax - row*dy`.
- Performance & ergonomics
  - Optimized build (`-O3 -flto -march=native`), progress every 1M lines, and clear errors.

Build
- In the project directory:
  - `make` — build optimized `blockminmax`.
  - `make release` — clean + rebuild with release flags.
  - `make debug` — clean + build with debug flags.
  - `make clean` — remove objects and binary.
  - Optional: `make install PREFIX=/usr/local`.

Usage (C binary)
- Min (default), Tcl‑like snapping and formatting:
  - `./blockminmax -Rxmin/xmax/ymin/ymax -Iinc -PATH input.xyz --tclround --tclfmt -o output.min`
- Max:
  - `./blockminmax -R... -I... -PATH input.xyz -MAX --tclround --tclfmt -o output.max`
- GMT‑like binning (matches `gmt blockmedian -E -C` with gridline registration):
  - `./blockminmax -R... -I... -PATH input.xyz --gmtbin -o output_gmt.min`

Notes
- `-PATH` (or `-path`) sets the input file; `-o` sets output file (default: `<input>.min`/`.max`).
- Without `--tclfmt`, C prints compact numeric output for `z`. With it, `x y` print at `%.1f`, `z` as original token.

Compare & visualize
The script runs Tcl, C, and GMT, normalizes output, compares sorted rows, and creates PNGs (shaded greens) for quick visual checks.

- Command (example; suppress opening images via `--no-open`):
  - `./compare_all.sh -R1585520.5/1587224.5/5464422.5/5467728.5 -I1 -P test.xyz`
- What it does
  - Tcl: `blockminmax.tcl -FIXMIN -TIELOW` → `tcl.min`.
  - C (Tcl‑like): `--tclround --tclfmt` → `c.min`.
  - C (GMT‑like): `--gmtbin` → `c_gmtbin.min`.
  - GMT: `gmt blockmedian -E -C` → `gmt.min` (formatted to `%.1f %.1f z`).
  - Sorts to `*.sorted`; reports IDENTICAL/DIFFER and line counts.
  - Builds `tcl.png`, `c.png`, `c_gmtbin.png`, `gmt.png`. Uses `open` on macOS (add `--no-open` to skip).

Requirements
- GMT 6.6 available on PATH for the GMT pipeline and visualization (xyz2grd, grdimage, psconvert).
- macOS `open` is optional; on other OSes use `--no-open`.

Quick references
- Tcl min with fix and tie‑low:
  - `tclsh blockminmax.tcl -R... -I1 -PATH test.xyz -FIXMIN -TIELOW`  → writes `test.xyz.min`.
- C Tcl‑like:
  - `./blockminmax -R... -I1 -PATH test.xyz --tclround --tclfmt -o test.xyz.c.min`.
- C GMT‑like:
  - `./blockminmax -R... -I1 -PATH test.xyz --gmtbin -o test.xyz.c_gmt.min`.
- GMT table min (for reference):
  - `gmt blockmedian test.xyz -R... -I1 -E -C | awk '{printf("%.1f %.1f %s\n", $1, $2, $5)}' > gmt.min`.

Outcomes
- Tcl vs C (Tcl‑like) now matches exactly when using `-FIXMIN` and `-TIELOW` on Tcl and `--tclround --tclfmt` on C.
- C (GMT‑like, `--gmtbin`) matches `gmt blockmedian -E -C` (gridline registration) on the same region/increment.

Tests
- Quick unit test (runs without GMT):
  - `make test`
  - or `bash test_blockminmax.sh`
- What it does
  - Builds a tiny XYZ dataset designed to highlight the differences between modes:
    - An out‑of‑bounds point near (0,0) within half a cell (tests clamp vs domain extension)
    - An exact 0.5/0.5 tie (tests tie handling in default vs Tcl‑like/GMT‑like)
    - Interior points at regular nodes
  - Runs blockminmax.c in three modes:
    - Default (llround + clamp), with native output formatting (no `--tclfmt`)
    - Tcl‑like: `--tclround --tclfmt` (nearest‑node, ties to lower, Tcl number style)
    - GMT‑like: `--gmtbin` (gridline registration mapping; node coordinates, k‑exact rounding)
  - Sorts each output and compares to a per‑mode reference; prints PASS/FAIL and exits non‑zero on first failure.
  - Expected: `PASS default`, `PASS tcllike`, `PASS gmtbin`, then `All tests passed`.
