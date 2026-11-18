#!/bin/zsh
# Checks the helper's one command, keeping this Mac awake, against what macOS itself reports
# (`pmset -g assertions`), using a scratch copy of the helper on another port. Takes about
# two minutes, most of it waiting for a one-minute hold to end.
#
#   ./check-awake.sh                  the copy from ./build.sh
#   ./check-awake.sh /path/to/fleetd  another copy
set -uo pipefail
cd "${0:A:h}"
bin=${1:-build/fleetd}
port=4799
file="$HOME/Library/Application Support/Fleet/awake-until"
if [[ -e $file ]]; then print -u2 "Fleet is keeping this Mac awake right now; stop that first, since this check uses the same file"; exit 2; fi

failed=0
check() { if [[ $2 == $3 ]]; then print "ok    $1"; else print "FAIL  $1: expected $3, got $2"; failed=1; fi }
start() { $bin --port $port 2>/dev/null & helper=$!; sleep 2; }
stop() { kill $helper 2>/dev/null; wait $helper 2>/dev/null; }
# What macOS says this helper is holding: 1 when it is keeping the Mac awake.
held() { pmset -g assertions | grep -c "pid $helper(fleetd).*Kept awake from Fleet"; }
code() { curl -s -m 5 -o /dev/null -w '%{http_code}' "$@"; }
says() { curl -s -m 8 http://127.0.0.1:$port/status | /usr/bin/python3 -I -c 'import json,sys; f=json.load(sys.stdin)["awake"]["fleet"]; print(f["on"], "until" in f)'; }
url=http://127.0.0.1:$port
trap 'stop; rm -f "$file"' EXIT

start
check "starts not holding the Mac awake" "$(held) $(says)" "0 False False"
check "a request without the X-Fleet header is refused" "$(code -X POST $url/awake/on) $(held)" "404 0"
check "a request a web page could send (with Origin) is refused" "$(code -X POST -H 'X-Fleet: 1' -H 'Origin: http://example.com' $url/awake/on) $(held)" "404 0"
check "the question a browser asks first gets no leave" "$(code -X OPTIONS -H 'Origin: http://example.com' -H 'Access-Control-Request-Headers: x-fleet' $url/awake/on)" "404"
check "a GET does nothing" "$(code -H 'X-Fleet: 1' $url/awake/on) $(held)" "404 0"
check "minutes outside 1 to 10080 are refused" "$(code -X POST -H 'X-Fleet: 1' "$url/awake/on?minutes=0") $(code -X POST -H 'X-Fleet: 1' "$url/awake/on?minutes=99999") $(held)" "404 404 0"
check "on: macOS shows the hold and the status says so" "$(code -X POST -H 'X-Fleet: 1' $url/awake/on) $(held) $(says)" "200 1 True False"
stop; start
check "a restarted helper takes the hold again" "$(held) $(says)" "1 True False"
check "off: the hold is gone" "$(code -X POST -H 'X-Fleet: 1' $url/awake/off) $(held) $(says) $([[ -e $file ]] && print file || print no-file)" "200 0 False False no-file"
check "on for one minute: held, with an end time" "$(code -X POST -H 'X-Fleet: 1' "$url/awake/on?minutes=1") $(held) $(says)" "200 1 True True"
sleep 85
check "85 seconds later the hold has ended by itself" "$(held) $(says) $([[ -e $file ]] && print file || print no-file)" "0 False False no-file"
exit $failed
