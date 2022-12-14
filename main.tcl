catch {
    package require starkit
    starkit::startup
}

proc d {arg} {
    # puts $arg
}

source "lib/c.tcl"
source "lib/trie.tcl"
namespace eval trie {
    namespace import ::ctrie::*
    namespace export *
    namespace ensemble create
}

namespace eval Statements { ;# singleton Statement store
    variable statements [dict create] ;# Dict<StatementId, Statement>
    variable nextStatementId 1
    variable statementClauseToId [trie create] ;# Trie<StatementClause, StatementId>
    proc reset {} {
        variable statements
        variable nextStatementId
        variable statementClauseToId
        set statements [dict create]
        set nextStatementId 1
        set statementClauseToId [trie create]
    }

    proc add {clause {parents {}}} {
        # empty set of parents = an assertion
        # returns {statement-id set-of-parents-id}
 
        variable statements
        variable nextStatementId
        variable statementClauseToId

        # is this clause already present in the existing statement set?
        set ids [trie lookup $statementClauseToId $clause]
        if {[llength $ids] == 1} {
            set id [lindex $ids 0]
        } elseif {[llength $ids] == 0} {
            set id false
        } else {
            error "WTF: Looked up {$clause}"
        }

        if {$id != false} {
            dict with statements $id {
                set newMatchId [expr {[lindex $parentMatches end-1] + 1}]
                dict set parentMatches $newMatchId $parents
                return [list $id $newMatchId]
            }
        } else {
            set id [incr nextStatementId]
            set stmt [statement create $clause [dict create 0 $parents]]
            dict set statements $id $stmt
            trie add statementClauseToId $clause $id

            return [list $id 0]
        }
    }
    proc exists {id} { variable statements; return [dict exists $statements $id] }
    proc get {id} { variable statements; return [dict get $statements $id] }
    proc remove {id} {
        variable statements
        variable statementClauseToId
        set clause [statement clause [get $id]]
        dict unset statements $id
        trie remove statementClauseToId $clause
    }
    proc size {} { variable statements; return [dict size $statements] }
    proc countMatches {} {
        variable statements
        set count 0
        dict for {_ stmt} $statements {
            set count [expr {$count + [dict size [statement parentMatches $stmt]]}]
        }
        return $count
    }
    
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
        variable statementClauseToId
        variable statements
        # Returns a list of bindings like
        # {{name Bob age 27 __matcheeId 6} {name Omar age 28 __matcheeId 7}}

        set matches [list]
        foreach id [trie lookup $statementClauseToId $pattern] {
            set match [unify $pattern [statement clause [get $id]]]
            if {$match != false} {
                dict set match __matcheeId $id
                lappend matches $match
            }
        }

        return $matches
    }

    proc print {} {
        variable statements
        puts "Statements"
        puts "=========="
        dict for {id stmt} $statements { puts "$id: [statement clause $stmt]" }
    }
    proc dot {} {
        variable statements
        set dot [list]
        dict for {id stmt} $statements {
            lappend dot "subgraph cluster_$id {"
            lappend dot "color=lightgray;"

            set label [statement clause $stmt]
            set label [join [lmap line [split $label "\n"] {
                expr { [string length $line] > 80 ? "[string range $line 0 80]..." : $line }
            }] "\n"]
            set label [string map {"\"" "\\\""} [string map {"\\" "\\\\"} $label]]
            lappend dot "$id \[label=\"$id: $label\"\];"

            dict for {matchId parents} [statement parentMatches $stmt] {
                lappend dot "\"$id $matchId\" \[label=\"$id#$matchId: $parents\"\];"
                lappend dot "\"$id $matchId\" -> $id;"
            }

            lappend dot "}"
            dict for {child _} [statement children $stmt] {
                lappend dot "$id -> \"$child\";"
            }
        }
        return "digraph { rankdir=LR; [join $dot "\n"] }"
    }
}

namespace eval statement { ;# statement record type
    namespace export create
    proc create {clause {parentMatches {}} {children {}}} {
        # clause = [list the fox is out]
        # parents = [dict create 0 [list 2 7] 1 [list 8 5]]
        # children = [dict create [list 9 0] true]
        return [dict create \
                    clause $clause \
                    parentMatches $parentMatches \
                    children $children]
    }

    namespace export clause parentMatches children
    proc clause {stmt} { return [dict get $stmt clause] }
    proc parentMatches {stmt} { return [dict get $stmt parentMatches] }
    proc children {stmt} { return [dict get $stmt children] }

    namespace ensemble create
}

set ::log [list]

# invoke at top level, add/remove independent 'axioms' for the system
proc Assert {args} {lappend ::log [list Assert $args]}
proc Retract {args} {lappend ::log [list Retract $args]}

# invoke from within a When context, add dependent statements
proc Say {args} {
    upvar __whenId whenId
    upvar __statementId statementId
    set ::log [linsert $::log 0 [list Say [list $whenId $statementId] $args]]
}
proc Claim {args} { uplevel [list Say someone claims {*}$args] }
proc Wish {args} { uplevel [list Say someone wishes {*}$args] }
proc When {args} {
    set env [uplevel {
        set ___env $__env ;# inherit existing environment

        # get local variables and serialize them
        # (to fake lexical scope)
        foreach localName [info locals] {
            if {![string match "__*" $localName]} {
                dict set ___env $localName [set $localName]
            }
        }
        set ___env
    }]
    uplevel [list Say when {*}$args with environment $env]
}

proc StepImpl {} {
    # should this do reduction of assert/retract ?

    proc runWhen {__env __body} {
        if {[catch {dict with __env $__body} err]} {
            puts "$::nodename: Error: $err\n$::errorInfo"
        }
    }

    proc reactToStatementAddition {id} {
        set clause [statement clause [Statements::get $id]]
        if {[lindex $clause 0] == "when"} {
            # is this a When? match it against existing statements
            # when the time is /t/ { ... } with environment /env/ -> the time is /t/
            set unwhenizedClause [lreplace [lreplace $clause end-3 end] 0 0]
            set matches [concat [Statements::findMatches $unwhenizedClause] \
                             [Statements::findMatches [list /someone/ claims {*}$unwhenizedClause]]]
            set body [lindex $clause end-3]
            set env [lindex $clause end]
            foreach match $matches {
                set __env [dict merge \
                               $env \
                               $match \
                               [dict create __whenId $id __statementId [dict get $match __matcheeId]]]
                runWhen $__env $body
            }

        } else {
            # is this a statement? match it against existing whens
            # the time is 3 -> when the time is 3 /__body/ with environment /__env/
            proc whenize {clause} { return [list when {*}$clause /__body/ with environment /__env/] }
            set matches [Statements::findMatches [whenize $clause]]
            if {[Statements::unify [lrange $clause 0 1] [list /someone/ claims]] != false} {
                # Omar claims the time is 3 -> when the time is 3 /__body/ with environment /__env/
                lappend matches {*}[Statements::findMatches [whenize [lrange $clause 2 end]]]
            }
            foreach match $matches {
                set __env [dict merge \
                               [dict get $match __env] \
                               $match \
                               [dict create __whenId [dict get $match __matcheeId] __statementId $id]]
                runWhen $__env [dict get $match __body]
            }
        }
    }
    proc reactToStatementRemoval {id} {
        # unset all things downstream of statement
        set children [statement children [Statements::get $id]]
        dict for {child _} $children {
            lassign $child childId childMatchId
            if {![Statements::exists $childId]} { continue } ;# if was removed earlier
            set childMatches [statement parentMatches [Statements::get $childId]]
            set parentsInSameMatch [dict get $childMatches $childMatchId]

            # this set of parents will be dead, so remove the set from
            # the other parents in the set
            foreach parentId $parentsInSameMatch {
                dict with Statements::statements $parentId {
                    dict unset children $child
                }
            }

            dict with Statements::statements $childId {
                dict unset parentMatches $childMatchId

                # is this child out of parent matches? => it's dead
                if {[dict size $parentMatches] == 0} {
                    reactToStatementRemoval $childId
                    Statements::remove $childId
                }
            }
        }
    }

    # d ""
    # d "Step:"
    # d "-----"

    # puts "Now processing log: $::log"
    set ::logsize [llength $::log]
    while {[llength $::log]} {
        # TODO: make this log-shift more efficient?
        set entry [lindex $::log 0]
        set ::log [lreplace $::log 0 0]

        set op [lindex $entry 0]
        # d "$op: [string map {\n { }} [string range $entry 0 100]]"
        if {$op == "Assert"} {
            set clause [lindex $entry 1]
            # insert empty environment if not present
            if {[lindex $clause 0] == "when" && [lrange $clause end-2 end-1] != "with environment"} {
                set clause [list {*}$clause with environment {}]
            }
            lassign [Statements::add $clause] id matchId ;# statement without parents
            if {$matchId == 0} { reactToStatementAddition $id }

        } elseif {$op == "Retract"} {
            set clause [lindex $entry 1]
            # if {[Statements::existsByClause $clause]} {
            #     set ids [list [Statements::clauseToId $clause]]
            # } else {
                set ids [lmap match [Statements::findMatches $clause] {
                    dict get $match __matcheeId
                }]
            # }
            foreach id $ids {
                # puts "Retract-match $match"
                # Statements::print
                reactToStatementRemoval $id
                Statements::remove $id
            }

        } elseif {$op == "Say"} {
            set parents [lindex $entry 1]
            set clause [lindex $entry 2]
            lassign [Statements::add $clause $parents] id matchId
            # list this statement as a child under each of its parents
            foreach parentId $parents {
                dict with Statements::statements $parentId {
                    dict set children [list $id $matchId] true
                }
            }
            if {$matchId == 0} { reactToStatementAddition $id }
        }
    }

    if {[namespace exists Display]} {
        Display::commit ;# TODO: this is weird, not right level
    }
}

lappend auto_path "./vendor"
package require websocket

set ::acceptNum 0
proc handleConnect {chan addr port} {
    fileevent $chan readable [list handleRead $chan $addr $port]
}
proc handleRead {chan addr port} {
    chan configure $chan -translation crlf
    gets $chan line
    puts "Http: $chan $addr $port: $line"
    set headers [list]
    while {[gets $chan line] >= 0 && $line ne ""} {
        if {[regexp -expanded {^( [^\s:]+ ) \s* : \s* (.+)} $line -> k v]} {
            lappend headers $k $v
        } else { break }
    }
    if {[::websocket::test $::serverSock $chan "/ws" $headers]} {
        puts "WS: $chan $addr $port"
        ::websocket::upgrade $chan
        # from now the handleWS will be called (not anymore handleRead).
    } else { puts "Closing: $chan $addr $port $headers"; close $chan }
}
proc handleWS {chan type msg} {
    if {$type eq "text"} {
        if {[catch {::websocket::send $chan text [eval $msg]} err]} {
            if [catch {
                puts "$::nodename: Error on receipt: $err"
                ::websocket::send $chan text $err
            } err2] { puts "$::nodename: $err2" }
        }
    }
}
set ::nodename [info hostname]
if {[catch {set ::serverSock [socket -server handleConnect 4273]}]} {
    set ::nodename "[info hostname]-1"
    puts "$::nodename: Note: There's already a Folk node running on this machine."
    set ::serverSock [socket -server handleConnect 4274]
}
::websocket::server $::serverSock
::websocket::live $::serverSock /ws handleWS

set ::stepCount 0
set ::stepTime "none"
proc Step {} {
    # puts "$::nodename: Step"

    # TODO: should these be reordered?
    incr ::stepCount
    Assert $::nodename has step count $::stepCount
    Retract $::nodename has step count [expr {$::stepCount - 1}]
    set ::stepTime [time {StepImpl}]
}

source "lib/math.tcl"

# this defines $this in the contained scopes
Assert when /this/ has program code /__code/ {
    if {[catch $__code err] == 1} {
        puts "$::nodename: Error in $this: $err\n$::errorInfo"
    }
}

if {$tcl_platform(os) eq "Darwin"} {
    if {$tcl_version eq 8.5} {
        error "Don't use Tcl 8.5 / macOS system Tcl. Quitting."
    }
}

if {[info exists ::env(FOLK_ENTRY)]} {
    set ::entry $::env(FOLK_ENTRY)

} elseif {$tcl_platform(os) eq "Darwin"} {
    #     if {[catch {source [file join $::starkit::topdir laptop.tcl]}]} 
    set ::entry "laptop.tcl"

} else {
    set ::entry "pi/pi.tcl"
}

source $::entry
