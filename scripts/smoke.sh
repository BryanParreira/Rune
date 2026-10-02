#!/bin/zsh
# Drives the debug build through the things that must always work (in each shell), the
# speed of typing, and the clipboard protection, and
# prints PASS/FAIL per check. Run before every release (scripts/release.sh does).
#   make build && scripts/smoke.sh
# FISH=/path/to/fish tests fish too when it isn't on PATH.
setopt NO_NOMATCH
ROOT=${0:A:h:h}
APP="$ROOT/build/DerivedData/Build/Products/Debug/Rune.app/Contents/MacOS/Rune"
[[ -x $APP ]] || { echo "Build first: make build"; exit 2; }
LOGS=$(mktemp -d)
failures=0

# run <name> <shell> <seconds> <step delay> <steps…>: launch, wait, quit; output in $LOGS/<name>.
run() {
  local name=$1 shell=$2 seconds=$3 delay=$4 script=$5
  [[ -n $SMOKE_VERBOSE ]] && echo "  $(date +%T) start $name" >&2
  SHELL=$shell RUNE_DEBUG_STEP=$delay RUNE_DEBUG_SCRIPT="$script" "$APP" > "$LOGS/$name" 2>&1 &
  local pid=$!
  sleep $seconds
  # A test app that's still busy may not quit politely; never wait on it.
  kill $pid 2>/dev/null
  sleep 1
  kill -9 $pid 2>/dev/null
  wait $pid 2>/dev/null
  [[ -n $SMOKE_VERBOSE ]] && echo "  $(date +%T) done $name" >&2
}

# check <name> <description> <pattern…>: every pattern must appear in the output.
check() {
  local name=$1 description=$2; shift 2
  for pattern in "$@"; do
    if ! grep -Eq -- "$pattern" "$LOGS/$name"; then
      echo "FAIL  $description (missing: $pattern)"
      failures=$((failures + 1))
      return
    fi
  done
  echo "PASS  $description"
}

shells=(/bin/zsh /bin/bash)
fish=${FISH:-$(command -v fish)}
[[ -n $fish && -x $fish ]] && shells+=($fish) || echo "skip  fish (not installed; set FISH=/path/to/fish)"

for shell in $shells; do
  name=blocks-${shell:t}
  run $name $shell 20 2 "@wait||echo smoke-ok||false||@dump||@gap"
  check $name "${shell:t}: blocks, exit codes, output above the input" \
    "DUMP block echo smoke-ok exit=0" "DUMP block false exit=1" "GAP .*gap=10\.0 mode=editor"
done

run vim /bin/zsh 22 2 "@wait||@dump||vim -u NONE||@wait||@dump||@send::q!||@wait||@dump"
rows=$(grep -Eo "DUMP screen .*rows=[0-9]+" "$LOGS/vim" | grep -Eo "rows=[0-9]+" | sort -u | wc -l | tr -d ' ')
if [[ $rows == 1 ]] && grep -q "mode=fullscreenApp" "$LOGS/vim" && grep -q "DUMP block vim -u NONE exit=0" "$LOGS/vim"; then
  echo "PASS  vim: full screen, same terminal size before/during/after, clean exit"
else
  echo "FAIL  vim: full screen and stable size ($rows sizes seen)"; failures=$((failures + 1))
fi

run output /bin/zsh 24 2 "@wait||seq 1 300000||@wait||@wait||@wait||@wait||@dump"
took=$(grep -Eo "DUMP block seq 1 300000 exit=0 took=[0-9.]+" "$LOGS/output" | grep -Eo "[0-9.]+$")
if [[ -n $took ]] && (( took < 10 )); then
  echo "PASS  heavy output: 300,000 lines in ${took}s"
else
  echo "FAIL  heavy output: 300,000 lines (took: ${took:-did not finish})"; failures=$((failures + 1))
fi

run wide /bin/zsh 16 2 "@wait||printf '%0400d\\n' 0; echo '漢字 テスト 🎉 👩‍💻 émoji'||@dump||@gap"
check wide "long lines, wide characters and emoji" "DUMP block printf .* exit=0" "GAP .*gap=10\.0"

run resize /bin/zsh 16 2 "@wait||@size:700x480||echo after-resize||@frame||@dump"
check resize "resizing the window keeps working" "FRAME window=\(700\.0, 480\.0\)" "DUMP block echo after-resize exit=0"

run menu /bin/zsh 14 1.2 "@wait||cd /tmp||@type:git ch||@key:tab||@menu"
check menu "completion menu opens with choices" "MENU open=true .*checkout"

run keys /bin/zsh 12 1 "@wait||@type:git push origin main||@chord:ctrl+w||@chord:ctrl+u||@chord:ctrl+y"
check keys "shell editing keys" "KEY ctrl\+w → <git push origin >" "KEY ctrl\+u → <>" "KEY ctrl\+y → <git push origin >"

run find /bin/zsh 14 1.2 "@wait||printf 'needle\\nhay\\nneedle\\n'||@find||@findQuery:needle"
check find "find in output" "FIND open=true matches=[3-9]"

run copy /bin/zsh 14 1.5 "@wait||printf 'a  \\nb\\n'||@copy:output"
check copy "copy output (trailing spaces trimmed)" "COPY output <<a"

run clipboard /bin/zsh 18 2 "@wait||@clipboardWrite||@wait||@clipboardProbe"
check clipboard "programs can set the clipboard but never read it" "CLIPBOARD write=true" "CLIPBOARD leaked=false"

run typing /bin/zsh 12 2 "@wait||@typeTimed:git commit -m 'fix the thing in src/app.ts' && npm test"
avg=$(grep -Eo "TYPING keys=[0-9]+ avg=[0-9.]+" "$LOGS/typing" | grep -Eo "[0-9.]+$")
if [[ -n $avg ]] && (( avg < 4 )); then
  echo "PASS  typing in the input: ${avg} ms per keystroke"
else
  echo "FAIL  typing in the input: ${avg:-no result} ms per keystroke (limit 4)"; failures=$((failures + 1))
fi

echo
if (( failures == 0 )); then
  echo "All checks passed. Also run the manual list in docs/RELEASE-CHECKLIST.md."
  rm -rf "$LOGS"
else
  echo "$failures check(s) failed. Logs: $LOGS"
  exit 1
fi
