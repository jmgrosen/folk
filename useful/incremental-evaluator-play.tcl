set ::statements [dict create]

set ::log [list]
proc Assert {args} {lappend ::log [list Assert $args]}
proc Retract {args} {lappend ::log [list Retract $args]}

proc Claim {args} {
    upvar __parents __parents
    lappend ::log [list Claim $__parents $args]
}

proc Step {cb} {
    # clear the statement set
    set ::statements [dict create]
    set ::whens [list]
    set ::currentMatchStack [dict create]
    uplevel 1 $cb ;# run the body code

    while 1 {
        set prevStatements $::statements
        evaluate
        if {$::statements eq $prevStatements} break ;# fixpoint
    }
}

proc Step {} {
    # should this do reduction of assert/retract ?

    proc unify {a b} {
        if {[llength $a] != [llength $b]} { return false }

        set match [dict create]
        for {set i 0} {$i < [llength $a]} {incr i} {
            set aWord [lindex $a $i]
            set bWord [lindex $b $i]
            if {[regexp {^/([^/]+)/$} $aWord -> aVarName]} {
                dict set match $aVarName $bWord
            } elseif {[regexp {^/([^/]+)/$} $bWord -> bVarName]} {
                dict set match $bVarName $aWord
            } elseif {$aWord != $bWord} {
                return false
            }
        }
        return $match
    }
    proc findMatches {pattern} {
        # Returns a list of bindings like {{name Bob age 27 __parents {...}} {name Omar age 28 __parents {...}}}
        # TODO: multi-level matching
        # TODO: efficient matching
        set matches [list]
        dict for {stmt _} $::statements {
            set match [unify $pattern $stmt]
            if {$match != false} {
                # store a set including {pattern, stmt} in match so
                # that when match is evaluated for when-body, it can
                # add itself as a child of pattern and of stmt
                dict set match __parents [list $pattern $stmt]

                lappend matches $match
            }
        }
        return $matches
    }

    puts ""
    puts "Step:"
    puts "-----"

    while {[llength $::log]} {
        # TODO: make this log-shift more efficient?
        set entry [lindex $::log 0]
        set ::log [lreplace $::log 0 0]

        set op [lindex $entry 0]
        puts "$op: $entry"
        if {$op == "Assert"} {
            set clause [lindex $entry 1]
            dict set ::statements $clause [list] ;# empty list = no children-statements yet

            if {[lindex $clause 0] == "when"} {
                # is this a When? match it against existing statements
                # when the time is /t/ { ... } -> the time is /t/
                set unwhenizedClause [lreplace [lreplace $clause end end] 0 0]
                set matches [findMatches $unwhenizedClause]
                set body [lindex $clause end]
                foreach bindings $matches {
                    dict with bindings $body
                }

            } else {
                # is this a statement? match it against existing whens
                # the time is 3 -> when the time is 3 /__body/
                set whenizedClause [list when {*}$clause /__body/]
                set matches [findMatches $whenizedClause]
                foreach bindings $matches {
                    dict with bindings [dict get $bindings __body]
                }
            }

        } elseif {$op == "Retract"} {
            set clause [lindex $entry 1]
            dict for {stmt _} $::statements {
                set match [unify $clause $stmt]
                if {$match != false} {
                    dict unset ::statements $stmt
                }
            }
            # FIXME: unset all things downstream of statement
            

        } elseif {$op == "Claim"} {
            set parents [lindex $entry 1]
            set clause [lindex $entry 2]
            puts "MAKING CLAIM $entry WITH PARENTS $parents"
            # list this statement as a dependent under all its parents
            dict with ::statements {
                foreach parent $parents { lappend $parent $clause }
            }
            dict set ::statements $clause [list] ;# empty list = no children-statements yet
        }
    }
}

# Single-level
# ------------

# the next 2 assertions should work in either order
Assert the time is 3
Assert when the time is /t/ {
    puts "the time is $t"
}
Step ;# should output "the time is 3"

Retract the time is 3
Assert the time is 4
Step ;# should output "the time is 4"

Retract when the time is /t/ /anything/
Retract the time is 4
Assert the time is 5
Step ;# should output nothing

Retract the time is /t/
Step ;# should output nothing
puts "statements: {$::statements}" ;# should be empty set

# Multi-level
# -----------

Assert when the time is /t/ {
    puts "parents: $__parents"
    Claim the time is definitely $t
}
Assert when the time is definitely /ti/ {
    puts "i'm sure the time is $ti"
}
Assert the time is 6
Step ;# FIXME: should output "i'm sure the time is 6"
puts "log: {$::log}"
puts "statements: {$::statements}"
