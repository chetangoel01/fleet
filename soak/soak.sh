#!/bin/zsh
# Overnight sampler. Runs on the Mac it samples, started by soak-start.sh.
# Every EVERY seconds it asks fleetd for its status once (standing in for a menu
# that refreshes once a minute) and records what the helper has cost so far.
# It stops by itself at END (epoch seconds), so nothing is left running.
#
#   soak.sh END [EVERY]        appends to soak.csv beside this script
zmodload zsh/datetime
end=$1 every=${2:-60}
here="${0:A:h}"
log="$here/soak.csv"
print $$ > "$here/soak.pid"
[[ -s $log ]] || print "epoch,time,pid,ps_cpu_s,cpu_s,tools_cpu_s,requests,tools_run,rss_kb,footprint_kb,fds,threads,sys_files,http,took_ms,total_ms,unknown,slow_ms" > $log

field() { print -r -- "$helper" | sed -n "s/.*\"$1\":\([0-9.]*\).*/\1/p" }

while (( EPOCHSECONDS < end )); do
    start=$EPOCHREALTIME
    reply=$(curl -s -m 20 -w '\n%{http_code}' http://127.0.0.1:4790/status)
    printf -v total '%.0f' $(( (EPOCHREALTIME - start) * 1000 ))
    code=${reply##*$'\n'}
    body=${reply%$'\n'*}
    took=$(print -r -- "$body" | sed -n 's/.*"took_ms":\([0-9]*\).*/\1/p')
    slow=$(print -r -- "$body" | sed -n 's/.*"slow_ms":{\([^}]*\)}.*/\1/p' | tr -d '"' | tr ',' ' ')   # which readings were slow
    unknown=$(print -r -- "$body" | grep -o '"state":"unknown"' | wc -l | tr -d ' ')              # readings that could not be taken
    helper=$(print -r -- "$body" | sed -n 's/.*"helper":{\([^}]*\)}.*/\1/p')   # the helper's own count of its CPU and its tools' CPU

    pid=$(launchctl list | awk '$3 == "com.chetangoel.fleetd" && $1 != "-" { print $1 }')   # the launchd copy, not a test copy
    if [[ -n $pid ]]; then
        cpu=$(ps -o time= -p $pid | awk -F: '{ if (NF == 3) print $1 * 3600 + $2 * 60 + $3; else print $1 * 60 + $2 }')
        rss=$(ps -o rss= -p $pid | tr -d ' ')
        fp=$(footprint -p $pid 2>/dev/null | awk '/phys_footprint:/ { v = $2; if ($3 == "MB") v *= 1024; if ($3 == "GB") v *= 1048576; printf "%d", v; exit }')
        fds=$(lsof -n -p $pid 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
        threads=$(ps -M -p $pid 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    else
        cpu= rss= fp= fds= threads=
    fi
    print "$EPOCHSECONDS,$(strftime %H:%M:%S $EPOCHSECONDS),$pid,$cpu,$(field cpu_s),$(field tools_cpu_s),$(field requests),$(field tools_run),$rss,$fp,$fds,$threads,$(sysctl -n kern.num_files),$code,$took,$total,$unknown,$slow" >> $log
    sleep $every
done
