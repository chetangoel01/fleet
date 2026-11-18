#!/bin/zsh
# Edge cases and loads for fleetd. Runs on the Mac under test, from the soak's
# working folder, against the copy launchd started (or a throwaway second copy on another
# port where the test needs to break something). Nothing here touches Docker, the
# drives or any other service. Run it through edge-run.sh, which keeps a log.
#
#   edge.sh burst | flood | silent | garbage | freeze | kill | cold | conflict | hung-docker | stuck-tool | fd-limit | cpu-load
#
# Every test cleans up after itself, and a watchdog ends the script after four
# minutes whatever happens, so a dropped ssh connection cannot leave load running.
port=4790
url=http://127.0.0.1:$port/status
bin=/Applications/Fleet.app/Contents/Helpers/fleetd
py=/usr/bin/python3
tmp=${TMPDIR:-/tmp}
label=com.chetangoel.fleetd
test=${1:-}

helper_pid() { launchctl list | awk -v l=$label '$3 == l && $1 != "-" { print $1 }' }
stats() { curl -s -m 20 ${1:-$url} | sed -n 's/.*"helper":{\([^}]*\)}.*/\1/p' }      # the helper's own counters
num() { print -r -- "$1" | sed -n "s/.*\"$2\":\([0-9.]*\).*/\1/p" }
secs() { ps -o time= -p $1 2>/dev/null | awk -F: '{ if (NF == 3) print $1 * 3600 + $2 * 60 + $3; else if (NF == 2) print $1 * 60 + $2 }' }
shape() { print "fds $(lsof -n -p $1 2>/dev/null | tail -n +2 | wc -l | tr -d ' ') threads $(ps -M -p $1 2>/dev/null | tail -n +2 | wc -l | tr -d ' ') footprint $(footprint -p $1 2>/dev/null | awk '/phys_footprint:/ { print $2 $3; exit }')" }
ok() { [[ $(curl -s -m 10 -o /dev/null -w '%{http_code}' ${1:-$url}) == 200 ]] }
took() { curl -s -m 20 ${1:-$url} | sed -n 's/.*"took_ms":\([0-9]*\).*/\1/p' }
yesno() { [[ $1 == 0 ]] && print yes || print no }
port_free() { ! nc -z 127.0.0.1 $1 2>/dev/null }

children=()
pid=$(helper_pid)
cleanup() {
    kill -CONT $pid 2>/dev/null
    kill $children $watchdog 2>/dev/null
    rm -f $tmp/fleet-hung.sock $tmp/fleetd-conflict.$$
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
( sleep 240; kill -TERM $$ ) >/dev/null 2>&1 & watchdog=$!     # detached from our output, or callers would wait for it

before=$(stats)
print "before: pid $pid, $(shape $pid), $before"
result=1 detail=

case $test in
burst)  # 300 requests one after another
    good=0; start=$SECONDS
    for i in {1..300}; do ok && (( good++ )); done
    [[ $good == 300 ]]; result=$?; detail="$good of 300 answered in $(( SECONDS - start )) s"
    ;;
flood)  # 200 requests, 50 at a time
    codes=$(seq 200 | xargs -P 50 -I{} curl -s -m 20 -o /dev/null -w '%{http_code}\n' $url | sort | uniq -c | tr -s ' \n' ' ')
    [[ $codes == " 200 200 " ]]; result=$?; detail="status codes (count code):$codes"
    ;;
silent)  # 150 connections that never send anything; the helper should drop each within 20 s
    counts=($($py -I -c '
import socket, select, time
conns, refused = [], 0
for _ in range(150):
    try: conns.append(socket.create_connection(("127.0.0.1", 4790)))
    except OSError: refused += 1      # more arrived at once than the kernel queues for a busy listener
time.sleep(24)
closed = 0
for c in conns:
    r, _, _ = select.select([c], [], [], 0)
    if not r: continue
    try:
        if c.recv(1) == b"": closed += 1
    except OSError:
        closed += 1
print(len(conns), closed, refused)'))
    ok; alive=$?
    [[ -n $counts[1] && $counts[1] == $counts[2] && $alive == 0 ]]; result=$?
    detail="$counts[2] of $counts[1] silent connections dropped by the helper, $counts[3] refused on arrival; still answering: $(yesno $alive)"
    ;;
garbage)  # malformed and hostile requests; each must get a 404 or a closed connection, never a status
    out=$($py -I -c '
import socket, os
cases = {
    "random bytes": os.urandom(4096),
    "no host header": b"GET /status HTTP/1.1\r\n\r\n",
    "foreign host": b"GET /status HTTP/1.1\r\nHost: example.com\r\n\r\n",
    "host as a suffix": b"GET /status HTTP/1.1\r\nHost: evil.example\r\nX-Host: 127.0.0.1:4790\r\n\r\n",
    "post": b"POST /status HTTP/1.1\r\nHost: 127.0.0.1:4790\r\n\r\n",
    "other path": b"GET /../../etc/passwd HTTP/1.1\r\nHost: 127.0.0.1:4790\r\n\r\n",
    "status with a suffix": b"GET /statusx HTTP/1.1\r\nHost: 127.0.0.1:4790\r\n\r\n",
    "huge header": b"GET /status HTTP/1.1\r\nX: " + b"a" * 200000 + b"\r\nHost: 127.0.0.1:4790\r\n\r\n",
    "cut short": b"GET /sta",
    "nul bytes": b"\x00" * 512,
}
bad = []
for name, payload in cases.items():
    s = socket.create_connection(("127.0.0.1", 4790)); s.settimeout(25)
    try:
        s.sendall(payload)
        if name == "cut short": s.shutdown(socket.SHUT_WR)
        reply = s.recv(65536)
    except OSError:
        reply = b""
    s.close()
    if b"200 OK" in reply: bad.append(name)
print(", ".join(bad) if bad else "none")')
    ok; alive=$?
    [[ $out == none && $alive == 0 ]]; result=$?; detail="bad requests answered with a status: $out; still answering: $(yesno $alive)"
    ;;
freeze)  # the helper is suspended for a while (as a sleeping Mac would), asked anyway, then resumed
    kill -STOP $pid
    failed=0
    for i in {1..6}; do curl -s -m 3 -o /dev/null $url || (( failed++ )); done
    kill -CONT $pid
    sleep 1; ok; alive=$?
    sleep 24   # connections queued while it was frozen should all be gone by now
    fds=$(lsof -n -p $pid 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    [[ $alive == 0 && $fds -lt 30 ]]; result=$?; detail="$failed of 6 requests timed out while frozen; answering 1 s after resuming: $(yesno $alive); open files afterwards $fds"
    ;;
kill)  # kill the helper outright; launchd should bring it back
    kill -9 $pid; start=$SECONDS; back=
    for i in {1..90}; do sleep 1; if ok; then back=$(( SECONDS - start )); break; fi; done
    [[ -n $back ]]; result=$?; detail="answering again after ${back:-more than 90} s as pid $(helper_pid)"
    ;;
cold)  # restart the helper and hit it at once, while its slow readings are still refreshing
    launchctl kickstart -k gui/$(id -u)/$label
    codes=$(seq 60 | xargs -P 20 -I{} curl -s -m 20 --retry 8 --retry-connrefused --retry-delay 1 -o /dev/null -w '%{http_code}\n' $url | sort | uniq -c | tr -s ' \n' ' ')
    [[ $codes == " 60 200 " ]]; result=$?; detail="status codes right after a restart (count code):$codes"
    ;;
conflict)  # a second copy on the same port must give up and leave the first alone
    $bin 2>$tmp/fleetd-conflict.$$ & second=$!; children+=($second)
    for i in {1..50}; do kill -0 $second 2>/dev/null || break; sleep 0.1; done
    if kill -0 $second 2>/dev/null; then gave_up=1; else gave_up=0; fi
    served=0; for i in {1..20}; do ok && (( served++ )); done
    [[ $gave_up == 0 && $served == 20 ]]; result=$?
    detail="second copy $([[ $gave_up == 0 ]] && print 'gave up' || print 'KEPT RUNNING on the same port'): $(head -c 160 $tmp/fleetd-conflict.$$ | tr '\n' ' '); first copy answered $served of 20"
    ;;
hung-docker)  # a Docker socket that accepts and never answers, as on 2026-11-18
    if ! port_free 4791; then detail="port 4791 is in use, test not run"; else
        sock=$tmp/fleet-hung.sock; rm -f $sock
        $py -I -c '
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(64); s.settimeout(1)
held = []; end = time.time() + 120
while time.time() < end:
    try: held.append(s.accept()[0])
    except socket.timeout: pass' $sock & children+=($!)
        sleep 1
        $bin --port 4791 --docker-socket $sock 2>/dev/null & copy=$!; children+=($copy)
        sleep 1
        times=(); slowest=0
        for i in {1..8}; do t=$(took http://127.0.0.1:4791/status); times+=($t); (( t > slowest )) && slowest=$t; sleep 5.5; done
        state=$(curl -s -m 20 http://127.0.0.1:4791/status | sed -n 's/.*"containers":{\([^}]*\)}.*/\1/p')
        fds=$(lsof -n -p $copy 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
        [[ $state == *unknown* && $fds -lt 30 && ${#times} == 8 && $slowest -lt 5000 ]]; result=$?
        detail="8 statuses took ${times} ms; containers reported {$state}; test copy ended with $(shape $copy), cpu $(secs $copy) s"
    fi
    ;;
stuck-tool)  # every tool a copy starts is frozen past its deadline, then let go
    if ! port_free 4793; then detail="port 4793 is in use, test not run"; else
        $bin --port 4793 2>$tmp/fleetd-conflict.$$ & copy=$!; children+=($copy)
        ( end=$(( SECONDS + 5 )); while (( SECONDS < end )); do pkill -STOP -P $copy 2>/dev/null; sleep 0.01; done; pkill -CONT -P $copy 2>/dev/null ) >/dev/null 2>&1 & children+=($!)
        sleep 0.3
        during=$(curl -s -m 40 http://127.0.0.1:4793/status | sed -n 's/.*"slow_ms":\({[^}]*}\).*"took_ms":\([0-9]*\).*/took \2 ms, slow \1/p')
        sleep 12
        if kill -0 $copy 2>/dev/null; then alive=0; else alive=1; fi
        next=$(took http://127.0.0.1:4793/status)
        fds=$(lsof -n -p $copy 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
        left=$(pgrep -P $copy | wc -l | tr -d ' ')
        [[ $alive == 0 && -n $next && $next -lt 2000 && $fds -lt 30 && $left -le 1 ]]; result=$?    # brew may still be running, with its own 60 s deadline
        detail="status while tools were frozen: ${during:-no answer}; afterwards alive: $(yesno $alive), next status ${next:-none} ms, open files $fds, tools still running $left; said: $(head -c 120 $tmp/fleetd-conflict.$$ | tr '\n' ' ')"
    fi
    ;;
fd-limit)  # a copy allowed only 20 open files, then flooded: it may refuse, but must not spin or die
    if ! port_free 4792; then detail="port 4792 is in use, test not run"; else
        ( ulimit -n 20; exec $bin --port 4792 2>$tmp/fleetd-conflict.$$ ) & copy=$!; children+=($copy)
        sleep 2
        codes=$(seq 120 | xargs -P 40 -I{} curl -s -m 10 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4792/status | sort | uniq -c | tr -s ' \n' ' ')
        sleep 6; cpu1=$(secs $copy); sleep 12; cpu2=$(secs $copy)     # nobody is asking during these 12 s
        if kill -0 $copy 2>/dev/null; then alive=0; else alive=1; fi
        ok http://127.0.0.1:4792/status; answers=$?
        printf -v spun '%.2f' $(( ${cpu2:-0} - ${cpu1:-0} ))
        [[ $alive == 0 && $answers == 0 ]] && (( spun <= 0.05 )); result=$?
        detail="codes under flood (count code):$codes; CPU while idle afterwards ${spun} s in 12 s; alive: $(yesno $alive); answers: $(yesno $answers); $(shape $copy); said: $(head -c 160 $tmp/fleetd-conflict.$$ | tr '\n' ' ')"
    fi
    ;;
cpu-load)  # every core busy for 50 s while the helper is asked for status
    cores=$(sysctl -n hw.ncpu)
    for i in {1..$cores}; do zsh -c 'SECONDS=0; while (( SECONDS < 50 )); do :; done' & children+=($!); done   # each stops by itself
    times=()
    for i in {1..8}; do times+=($(took)); sleep 5.5; done
    [[ ${#times} == 8 ]]; result=$?; detail="statuses with all $cores cores busy took ${times} ms"
    ;;
*)
    print "unknown test '$test'"; exit 2
    ;;
esac

sleep 6     # past the 5 s snapshot, so the counters below are current
after=$(stats); now=$(helper_pid)
print "after:  pid $now, $(shape $now), $after"
if [[ $now == $pid ]]; then
    tools=$(( $(num "$after" tools_run) - $(num "$before" tools_run) ))
    printf 'cost:   %d requests, helper CPU %.3f s, %d tools started using %.3f CPU s\n' $(( $(num "$after" requests) - $(num "$before" requests) )) $(( $(num "$after" cpu_s) - $(num "$before" cpu_s) )) $tools $(( $(num "$after" tools_cpu_s) - $(num "$before" tools_cpu_s) ))
    # hundreds of requests must share snapshots, not start a set of tools each
    if [[ $test == (burst|flood) ]] && (( tools > 40 )); then result=1; detail+="; started $tools tools"; fi
fi
if [[ $result == 0 ]]; then print "RESULT $test PASS: $detail"; else print "RESULT $test FAIL: $detail"; fi
