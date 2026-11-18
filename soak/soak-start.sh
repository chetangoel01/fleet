#!/bin/zsh
# Starts the overnight sampler on this Mac, m1-server and mini. Each one runs on
# its own Mac and stops by itself at the end time, so samples keep coming even if
# this MacBook sleeps. Run from m5-macbook.
#
#   soak/soak-start.sh "2026-11-18 10:00" [seconds between samples, default 60]
#   soak/soak-start.sh stop          stop all three now
#   soak/soak-start.sh clean         stop, copy each soak.csv into soak/results/, remove the test files from each Mac
set -uo pipefail
cd "${0:A:h}"
dir='$HOME/Library/Application Support/Fleet'    # expanded on the Mac it runs on
hosts=(local m1-server mini)

on() { if [[ $1 == local ]]; then zsh -c "$2"; else ssh -o BatchMode=yes -o ConnectTimeout=8 $1 "$2"; fi }
stop="cd \"$dir\" && { [[ -s soak.pid ]] && ps -o command= -p \$(<soak.pid) | grep -q soak.sh && kill \$(<soak.pid) && echo \"stopped on \$(scutil --get ComputerName)\" || echo \"not running on \$(scutil --get ComputerName)\"; }"

case ${1:-} in
stop)
    for h in $hosts; do on $h $stop; done
    ;;
clean)
    mkdir -p results
    for h in $hosts; do
        on $h $stop
        on $h "cat \"$dir/soak.csv\"" > results/${h/local/m5-macbook}.csv
        on $h "cd \"$dir\" && rm -f soak.sh edge.sh soak.csv soak.pid && ls"
    done
    ;;
*)
    end=$(date -j -f "%Y-%m-%d %H:%M" "$1" +%s) || exit 1
    every=${2:-60}
    for h in $hosts; do
        on $h $stop >/dev/null
        on $h "mkdir -p \"$dir\""
        if [[ $h == local ]]; then cp soak.sh edge.sh "$HOME/Library/Application Support/Fleet/"
        else scp -q soak.sh edge.sh "$h:Library/Application Support/Fleet/"; fi
        on $h "cd \"$dir\" && { nohup zsh ./soak.sh $end $every >/dev/null 2>&1 </dev/null &! }"
    done
    sleep 8
    for h in $hosts; do   # proof it started: a live pid and a first row
        on $h "cd \"$dir\" && echo \"\$(scutil --get ComputerName): sampler pid \$(<soak.pid) \$(ps -o command= -p \$(<soak.pid) | grep -q soak.sh && echo running || echo NOT RUNNING), \$(( \$(wc -l < soak.csv) - 1 )) rows, last: \$(tail -1 soak.csv)\""
    done
    ;;
esac
