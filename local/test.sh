#!/bin/bash
# Runs the access tests from inside the server container:
#   docker compose exec server /test.sh
# Expects the default test users (alice, bob, carol) and zones (team-a, team-b).
cd /tmp && echo "day 1 log" > log.txt && echo "MODIFIED" > other.txt && echo "doc" > doc.txt
S() { u=$1; sh=$2; shift 2; smbclient "//127.0.0.1/$sh" -U "$u%test1234" --client-protection=encrypt -c "$*" 2>&1; }
pass=0; fail=0
check() { # description, expected-pattern (or !pattern to require absence), output
  local d="$1" p="$2" out="$3" ok
  if [[ "$p" == !* ]]; then grep -q -- "${p:1}" <<<"$out" && ok=1 || ok=0; ok=$((1-ok)); else grep -q -- "$p" <<<"$out" && ok=1 || ok=0; fi
  if [ "$ok" = 1 ]; then echo "PASS  $d"; pass=$((pass+1)); else echo "FAIL  $d"; echo "$out" | sed 's/^/      /'; fail=$((fail+1)); fi
}
o=$(S alice Projects "ls");                         check "alice sees team-a in Projects" "team-a" "$o"; check "alice does not see team-b in Projects" "!team-b" "$o"
o=$(S alice Projects "cd team-a; put doc.txt");  check "alice can write in her project" "putting file" "$o"
o=$(S carol Projects "cd team-a; put other.txt doc.txt"); check "a colleague in the same group can edit that file" "putting file" "$o"
o=$(S bob Projects "cd team-a; ls");        check "bob is refused in team-a" "ACCESS_DENIED" "$o"
o=$(S alice Archive "ls");                           check "alice sees only her zone in Archive" "!team-b" "$o"
o=$(S alice Archive "cd team-b; ls");             check "alice is refused in archive team-b" "ACCESS_DENIED" "$o"
o=$(S alice Archive "cd team-a; put doc.txt");    check "archive is read-only" "ACCESS_DENIED" "$o"
f="log-$(date +%s).txt"
o=$(S alice Uploads "cd team-a; put log.txt $f");  check "alice can upload a file" "putting file" "$o"
o=$(S alice Uploads "cd team-a; put other.txt $f");   check "alice cannot overwrite it" "ACCESS_DENIED" "$o"
o=$(S alice Uploads "cd team-a; del $f");             check "alice cannot delete it" "ACCESS_DENIED" "$o"
o=$(S alice Uploads "cd team-a; rename $f x.txt");    check "alice cannot rename it" "ACCESS_DENIED" "$o"
o=$(S carol Uploads "cd team-a; get $f /tmp/j.txt");  check "a colleague in the group can read it" "getting file" "$o"
o=$(smbclient //127.0.0.1/Archive -U alice%wrong -c ls 2>&1); check "wrong password is refused" "LOGON_FAILURE" "$o"
echo; echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
