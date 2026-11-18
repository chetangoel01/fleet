#!/bin/zsh
# One look at the overnight test: anything needing attention in the last N samples
# (default 60), edge-test results since the previous look, and whether the samplers
# and the night runner are still going. Run from m5-macbook.
#
#   soak/checkin.sh [N]
cd "${0:A:h}"
n=${1:-60}
print "check-in $(date '+%H:%M:%S')"
print -- "-- needs a look (last $n samples):"
./soak-summary.sh alerts $n 2>/dev/null | sed 's/^/   /'
print -- "-- edge tests since the last look:"
seen=$(cat .edge-seen 2>/dev/null || print 0)
total=$(wc -l < edge-log.txt 2>/dev/null | tr -d ' ')
tail -n +$(( seen + 1 )) edge-log.txt 2>/dev/null | grep -E "^2026|RESULT" | cut -c1-330 | sed 's/^/   /'
print ${total:-0} > .edge-seen
print -- "-- still running:"
print "   night runner: $([[ -s night.pid ]] && ps -o etime= -p $(<night.pid) 2>/dev/null || print 'no')"
for h in local m1-server mini; do
    check='cd "$HOME/Library/Application Support/Fleet" && echo "$(scutil --get ComputerName): sampler $(ps -o command= -p $(<soak.pid) 2>/dev/null | grep -q soak.sh && echo running || echo STOPPED), $(( $(wc -l < soak.csv) - 1 )) samples, load $(sysctl -n vm.loadavg | cut -d" " -f2), last: $(tail -1 soak.csv | cut -d, -f2,3,10,11,13,14,15,17,18)"'
    if [[ $h == local ]]; then zsh -c $check; else ssh -o BatchMode=yes -o ConnectTimeout=8 $h $check 2>/dev/null; fi | sed 's/^/   /'
done
