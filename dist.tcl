#!/usr/bin/tclsh
set dist "TRAM.ZIP"
set content {
	MQL4
	deps
}
set 7z "C:/Program Files (x86)/7-Zip/7z"
catch { file delete $dist }
set dir [ file tail [ pwd ] ]
cd ..
foreach entry $content {
	exec $7z a -r [ file join $dir $dist ] [ file join $dir $entry ]
}

