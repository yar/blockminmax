#! /usr/bin/env tclsh

#like GMT blockmedian, but just report the minimum or maximum value for each cell
set usage "blockminmax.tcl -Rxmin/xmax/ymin/ymax \[-Iinc (default is 1)\] path_to_xyz_file \[-MAX\]\nblockmin.tcl -R1585520.5/1587224.5/5464422.5/5467728.5 -I0.5 -PATH /Users/robd/caves/nz/lidar/pointcloud/spittals.xyz.bm"

set find_min 1
set ending min
set preset 1e10
set gotregion 0
set gotpath 0
set inc 1
set fix_min 0
set tie_lower 0
for {set i 0} { $i < $argc} {incr i} {
  set arg [lindex $argv $i]
	if {[regexp {^-R} $arg]} {
		regsub {^-R} $arg {} region
		scan $region "%f/%f/%f/%f" xmin xmax ymin ymax
		set gotregion 1
		
	} elseif {[regexp {^-I} $arg]} {
		regsub {^I} $arg {} inc
    } elseif {[regexp {^-MAX} $arg]} {
        set find_min 0
        set ending max
        set preset -1e10
    } elseif {[regexp {^-FIXMIN} $arg]} {
		# When provided, correct the min/max update logic so that in
		# min mode we only accept smaller values and in max mode only
		# larger values. Default behavior retains original script logic.
        set fix_min 1
    } elseif {[regexp {^-TIELOW} $arg] || [regexp {^-TIELOWER} $arg]} {
        # When provided, break equal-distance ties toward the lower (smaller) grid value
        set tie_lower 1
	} elseif {[regexp {^-path} $arg] || [regexp {^-PATH} $arg]} {
		incr i
		set path [lindex $argv $i]
		if {![file exists $path]} {
			puts "no file $path...exit"
			puts $usage
		}
		set gotpath 1
	} else {
		puts $usage
		exit
	}
}

if {$gotregion && $gotpath} {
	puts "region $xmin $xmax $ymin $ymax"
} else {
	puts $usage
	exit
}


proc findClosestValue {orderedList targetValue} {
    global tie_lower
    set len [llength $orderedList]
    if {$len == 0} {
        return "Error: List is empty."
    }

    set low 0
    set high [expr {$len - 1}]
    set closestValue [lindex $orderedList 0] ;# Initialize with the first element
    set minDiff [expr {abs($targetValue - $closestValue)}]

    while {$low <= $high} {
        set mid [expr {($low + $high) / 2}]
        set currentValue [lindex $orderedList $mid]
        set currentDiff [expr {abs($targetValue - $currentValue)}]

        if {$currentDiff < $minDiff} {
            set minDiff $currentDiff
            set closestValue $currentValue
        } elseif {$currentDiff == $minDiff} {
            # Optional tie-breaking: choose the lower value when enabled
            if {$tie_lower && $currentValue < $closestValue} {
                set closestValue $currentValue
            }
        }

        if {$currentValue < $targetValue} {
            set low [expr {$mid + 1}]
        } elseif {$currentValue > $targetValue} {
            set high [expr {$mid - 1}]
        } else {
            # Target value found exactly
            return $currentValue
        }
    }

    # After the binary search loop, compare with the elements at 'low' and 'high' indices
    # as they might be the closest if the target wasn't found exactly.
    if {$low < $len} {
        set valueAtLow [lindex $orderedList $low]
        set diffAtLow [expr {abs($targetValue - $valueAtLow)}]
        if {$diffAtLow < $minDiff} {
            set closestValue $valueAtLow
            set minDiff $diffAtLow
        } elseif {$tie_lower && $diffAtLow == $minDiff && $valueAtLow < $closestValue} {
            set closestValue $valueAtLow
        }
    }
    if {$high >= 0} {
        set valueAtHigh [lindex $orderedList $high]
        set diffAtHigh [expr {abs($targetValue - $valueAtHigh)}]
        if {$diffAtHigh < $minDiff} {
            set closestValue $valueAtHigh
            set minDiff $diffAtHigh
        } elseif {$tie_lower && $diffAtHigh == $minDiff && $valueAtHigh < $closestValue} {
            set closestValue $valueAtHigh
        }
    }

    return $closestValue
}

set l_x ""
for {set x $xmin} {$x <= $xmax } {set x [format %.1f [expr {$x + 1.0}]]} {
	lappend l_x $x
} 
set l_y ""
for {set y $ymin} {$y <= $ymax } {set y [format %.1f [expr {$y + 1.0}]]} {
	lappend l_y $y
}

puts "[llength $l_x] columns by [llength $l_y] rows"

if {$find_min} {
	foreach x $l_x {
		foreach y $l_y {
			set ar($x,$y) $preset
		}
	}
} else {
	foreach x $l_x {
		foreach y $l_y {
			set ar($x,$y) $preset
		}
	}
}
puts "initialised ar(x,y)"

set fin [open $path r]
set lines 0
set Mlines 0
while {[gets $fin line] >0} {
	incr lines
	scan $line "%s %s %s" x y z
	set x [findClosestValue $l_x $x]
	set y [findClosestValue $l_y $y]
	if {$fix_min} {
		if {$find_min} {
			if {$z < $ar($x,$y)} {
				set ar($x,$y) $z
			}
		} else {
			if {$z > $ar($x,$y)} {
				set ar($x,$y) $z
			}
		}
	} else {
		# Original behavior: in min mode, accept smaller z, but also
		# overwrite with larger z due to the elseif; effectively last value wins.
		if {$find_min && $z < $ar($x,$y)} {
			set ar($x,$y) $z
		} elseif {$z > $ar($x,$y)} {
			set ar($x,$y) $z
		}
	}
	if {$lines == 1000000} {
		incr Mlines
		puts "$Mlines,000,000 lines"
		set lines 0
	}
}
puts "updated ar(x,y) with zmin"
close $fin

puts "write $path.$ending"
set fout [open $path.$ending w]
foreach x $l_x {
	foreach y $l_y {
		set z $ar($x,$y)
		if {$z != $preset} {
			puts $fout "$x $y $z"
		}
	}
}
close $fout
