## original script by Niels Roosen (niels at okkernoot dot net)
## modified for dnas v2 and other fixes by dlnetworks.net

## Set some configuration options

## Shoutcast configuration
	## Stream servers, format: { host_or_ip port stream_id }
	set shoutcast_relays {

	{ 127.0.0.1 80 1 }
	{ host.domain.com 8000 1 }
	{ 127.0.0.1 8030 1 }
	{ 127.0.0.1 8050 1 }
	{ host.domain.com 80 2 }
	{ 127.0.0.1 8000 2 }
	{ host.domain.com 8030 2 }
	{ 127.0.0.1 8050 2 }
}
 
	## Channel to show shoutcast stats on
	set shoutcast_channels { "#channel" }

	## Interval for showing stats
	set shoutcast_show_interval 60

	## Name of the radio station
	set shoutcast_station_name "Radio Station"

## End of shoutcast configuration
	
package require http
package require tdom 

bind pub - ".record" show_listener_record
bind msg - ".stat" msg_show_stats
bind pub - ".stat" pub_show_stats
bind msg - ".stats" msg_show_stats
bind pub - ".stats" pub_show_stats
bind time - "?? * * * *" timer_show_stats

### CODE STARTS HERE ###

# Set show_stats semaphore
set sem_show_shoutstats 0

# Set show_stats counter
set counter_show_shoutstats $shoutcast_show_interval

proc test_stats {n m h c a} {
	after 0 [timer_show_stats 0 0 0 0 0]
}

proc pub_show_stats {nick mask hand channel args} {
	after 0 [show_shoutstats $channel "requested"]
}

proc msg_show_stats {nick mask hand channel args} {
	after 0 [show_shoutstats $nick "requested"]
}

proc timer_show_stats {mi ho da mo ye} {
	after 0 [show_shoutstats "#" "timer"]
}

proc show_listener_record {nick hand channel args} {
	after 0 [show_shoutstats $channel "record"]
}

set shoutcast_station_name2 "$shoutcast_station_name"


proc show_shoutstats {channel mode} {
	global shoutcast_relays sem_show_shoutstats shoutcast_show_interval \
		shoutcast_station_name2 shoutcast_station_name counter_show_shoutstats shoutcast_channels \
		homedir
	set run_allowed 0
	
	## First wait for any other show functions to complete w/ some test-and-set instruction
	while { $run_allowed == 0 } {
		if { ( $sem_show_shoutstats == 0 ) && ( [set sem_show_shoutstats 1] ) && ( [set run_allowed 1] ) } {
			## Continue the function
		} else {
			vwait $sem_show_shoutstats
			putserv "PRIVMSG $channel: I was delayed for execution"
		}
	}
	
	# Initialize the total stats
	# Per relay: { quality { current max bandwidth }}
	set total_stats {}

	# Totals current max bandwidth
	set t_unique 0
	set t_maxlst 0
	set t_bw 0.0

	# Extract data per relay
	foreach relay $shoutcast_relays {
		
		# Get attributes
		set server [lindex $relay 0]
		set port [lindex $relay 1]
		set sid [lindex $relay 2]
		set mark [lindex $relay 3]

		# Get the actual data
		if { [catch {::http::geturl "http://$server:$port/7.html?sid=$sid" \
			-timeout 5000 -headers "User-Agent: Mozilla (The King Kong of Lawn Care)"} stats_token] } {
			continue
		} else {
			# DO NOTHING
			set status [::http::status $stats_token]
			if { $status != "ok" } {
				continue
			}
		}
		set stats_data [::http::data $stats_token]

		# Get the stats from the html body
		set begin [expr [string first "<body>" $stats_data] + 6]
		set end [expr [string first "</body>" $stats_data] - 1]
		set relay_rawstats [string range $stats_data $begin $end]

		# Now extract the max-allowed and unique listener stats from the string
		set relay_liststats [split $relay_rawstats ","]

		set relay_unique [lindex $relay_liststats 1]
		set relay_maxlst [lindex $relay_liststats 3]
		set quality [lindex $relay_liststats 5]
		set relay_bw [expr ($quality * $relay_unique) / 1024.0 ]

		# Accumulate this to the totals
		# First check if this quality already appears in the totals list
		# And eventually search for the index where it should be inserted then
		set length [llength $total_stats]
		if { $length == 0 } {
			# The list is yet empty
			set q_totals [list $quality [list $relay_unique $relay_maxlst $relay_bw]]
			set total_stats [concat $total_stats $q_totals]
		} else {
			# Search for the right quality in the index
			# First try to find it in the list
			for { set q_index 0 } { $q_index <= $length } { set q_index [expr $q_index + 2] } {
				if { [lindex $total_stats $q_index] == $quality } {
					break
				}
			}
			
			if { $q_index > $length } {
				# It doesnt exist yet
				# Now we have to insert it in the list
				for { set q_index 0 } { ($quality > [lindex $total_stats $q_index]) \
					&& ($q_index < $length) } { set q_index [expr $q_index + 2] } {
				}
				if { $q_index > $length } {
					# We have to append it to the list
					set q_totals [list $quality [list $relay_unique $relay_maxlst $relay_bw]]
					set total_stats [concat $total_stats $q_totals]
				} else {
					# We have to insert it in the list
					set q_totals [list $quality [list $relay_unique $relay_maxlst $relay_bw]]
					# First put it behind the first part of the list
					set total_stats_first [lrange $total_stats 0 [expr $q_index - 1]]
					set total_stats_last [lrange $total_stats $q_index end]
					set total_stats [concat $total_stats_first $q_totals]
					set total_stats [concat $total_stats $total_stats_last]
				}
			} else {
				# The stats for this quality already exist, add it to them
				# First get the current stats
				set cq_totals [lindex $total_stats [expr $q_index + 1]]

				# Add them together
				set q_unique [expr $relay_unique + [lindex $cq_totals 0]]
				set q_maxlst [expr $relay_maxlst + [lindex $cq_totals 1]]
				set q_bw [expr $relay_bw + [lindex $cq_totals 2]]
				
				# Replace the qurrent values in the totals
				set q_totals [list $q_unique $q_maxlst $q_bw]
				set total_stats [lreplace $total_stats [expr $q_index + 1] [expr $q_index + 1] $q_totals]
			}
		}

		# And accumulate this to the absolute totals
		set t_unique [expr $t_unique + $relay_unique]
		set t_maxlst [expr $t_maxlst + $relay_maxlst]
		set t_bw [expr $t_bw + $relay_bw]
		
		::http::cleanup $stats_token
	}

	# Reset the show_stats_now var
	set show_stats_now 0

	# Truncate the bandwidth
	set t_bw [format "%.2f" $t_bw]

	# Now, before we display anything, check if the record is broken
	# If so, we dont display the stats but display a new record notice instead
	# Format of the file:
	#
	# Date\tListeners\tBw
	
	# First try to open the file
	if { [file exists "./$shoutcast_station_name.record"] == 1 } {
		set statfile [open "./$shoutcast_station_name.record" r]
		set record [read $statfile]
		close $statfile
	
		set frecord [split $record "\t"]

		# Now check if there was already something in the file
		if { [llength $frecord] != 4 } {
			set record_broken 1
		} elseif { [lindex $frecord 2] < $t_unique } {
			set record_broken 1
		} else {
			set record_broken 0
		}
	} else {
		# The file didnt exist
		set record_broken 1
	}
	
	# Now, check if we are gonna show the stats or the new record
	if { $record_broken == 1 } {
		# Re-open the statfile
		set statfile [open "./$shoutcast_station_name.record" w]

		# Insert the new data in the file
		set current_time [clock seconds]
		set ctime [clock format $current_time -format "%A %m-%d-%Y %H:%M"]
		
		set current_song [lindex $shoutcast_now_playing 0]
		puts -nonewline $statfile "$ctime\t$t_unique\t$t_bw"
	
		## Be sure to close the file
		close $statfile

		set outputs "$shoutcast_station_name2 new record - Listener record broken on $ctime with $t_unique listeners."
		# Now print the record to the chat
		if { $mode == "timer" } {
			# For each shoutcast channel
			foreach chan $shoutcast_channels {
				putquick "PRIVMSG $chan :$outputs"
			}
		} else {
			# For the specified channel
			putquick "PRIVMSG $channel :$outputs"
		}
	} else {
		# Perform the command requested (timer, requested or record)
		if { $mode == "record" } {
			set rsong [lindex $frecord 0]
			set rtime [lindex $frecord 1]
			set rlst [lindex $frecord 2]
			set rbw [lindex $frecord 3]
			set outputs "$shoutcast_station_name2 record - Current record was set on $rtime with $rlst listeners."
			putquick "PRIVMSG $channel :$outputs"
		} else {
			# Format all stats in one line
			set outputs "$shoutcast_station_name2 Stats:"
		
			foreach {q s} $total_stats {
				set current [lindex $s 0]
				set max [lindex $s 1]
				set bw [format "%.2f" [lindex $s 2]]
				set outputs "$outputs ($q Kbps - $current/$max/$bw Mbps)"
			}
			set outputs "$outputs (Total - $t_unique/$t_maxlst/$t_bw Mbps)"
	
			if { $mode == "requested" } {
				# It seems we have a normal channel
				putquick "PRIVMSG $channel :$outputs"
			} else {
				# Just assume this is a timer thing
				set counter_show_shoutstats [expr $counter_show_shoutstats - 1]
				# putserv "PRIVMSG $channel :Decreasing counter to $counter_show_shoutstats"
				if { $counter_show_shoutstats <= 0 } {
					set counter_show_shoutstats $shoutcast_show_interval

					# Now display those stats
					foreach chan $shoutcast_channels {
						putquick "PRIVMSG $chan :$outputs"
					}
				}
			}
		}
	}

	## Free the semaphore
	set sem_show_shoutstats 0
}

###############################
# Execute the show_stats
show_shoutstats "#" "timer"

putlog "multi server shoutcast listener stats tcl for eggdrop loaded..."
