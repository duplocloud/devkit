#!/usr/bin/env bash
# Checks strip_term_noise() and prompt() in run.sh: the sanitizer that removes terminal escape
# sequences and other control bytes from values read interactively, and the single helper every
# interactive prompt (email, password, API keys, the LLM-provider menu) is required to go through.
#
# Why this exists: `read` with no `-e` has no line editor to intercept special keys, so a terminal that
# sends an escape sequence during a prompt — an arrow key, a focus report, a bracketed-paste marker, a
# cursor-position reply — lands as literal bytes in the captured string. Concretely observed: an Up/Down
# arrow at the email prompt in a Windows Git-Bash session stored `<ESC>[A<ESC>[B` ahead of the typed
# address, so Authentication__LocalAdminEmail/SuperUsers never matched what the user actually typed and
# login silently failed. A review on the PR that introduced strip_term_noise then found the same gap
# still open on two other prompts (a license-rejected-email retry, and the LLM-provider menu) that read
# directly with `read -r` instead of going through it — hence prompt(): one helper, used everywhere, so
# a future prompt can't be added without sanitization the same way. It also switches to `read -e`
# (readline), which consumes an arrow key/paste/focus sequence as editing input in the first place —
# strip_term_noise stays behind it as a second line of defense for whatever readline doesn't bind.
#
# This extracts both functions straight from run.sh (not a copy) so they can never drift out of sync
# with the shipped code, then checks strip_term_noise against the real escape-sequence grammar (ECMA-48
# CSI and SS3 forms) plus negative cases that must survive byte-for-byte, and checks prompt() for
# correct sanitization, secret-vs-plain handling, and correct EOF/exit-status propagation in both
# branches — a literal first draft of prompt() sequenced `read -res ...; echo >&2` in the secret branch,
# which left the branch's own exit status as echo's (always 0), silently swallowing a real EOF on the
# password prompt specifically; prompt() captures `read`'s status into a local before the echo runs.
#
# Static + pure-function only: nothing here starts the stack or needs any runtime installed. The
# interactive-read checks pipe input instead of driving a real pty, so they prove sanitization/exit-code
# correctness, not that readline itself consumes a raw escape sequence — that part is standard,
# well-established GNU Readline behavior (the same arrow-key bindings every interactive bash session
# already relies on), not new logic this repo introduces.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

t "run.sh is syntactically valid and defines strip_term_noise and prompt"
if bash -n run.sh 2>/dev/null && grep -q '^strip_term_noise() {' run.sh && grep -q '^prompt() {' run.sh; then ok
else bad "missing/syntax error"; exit 1; fi

t "every interactive read in run.sh goes through prompt() (none bypass sanitization)"
# prompt()'s own body is the one place real `read -p` calls are allowed to live; strip its lines out
# (not just its declaration line) before checking for a stray one anywhere else in the file.
outside="$(awk '/^prompt\(\) \{/{skip=1} skip{if(/^}/)skip=0; next} {print}' run.sh | grep -nE "read -r?e?s? -p" || true)"
if [ -z "$outside" ]; then ok; else bad "a raw 'read ... -p' exists outside prompt(): $outside"; fi

# Pull the function verbatim out of run.sh — this is what actually ships, not a reimplementation.
eval "$(awk '/^strip_term_noise\(\) \{/,/^}/' run.sh)"

E=$'\033'  # ESC
check() { # name input expected
  local name="$1" input="$2" expected="$3" got
  got="$(strip_term_noise "$input")"
  t "$name"
  if [ "$got" = "$expected" ]; then ok; else bad "input=$(printf '%q' "$input") expected=$(printf '%q' "$expected") got=$(printf '%q' "$got")"; fi
}

echo "strip_term_noise — real escape sequences (must be fully removed):"
check "CSI Up, twice in a row (the exact observed bug)" "${E}[A${E}[Badmin.user@example.com" "admin.user@example.com"
check "CSI Down alone"                              "${E}[Bjane@x.com"             "jane@x.com"
check "CSI Right alone"                             "${E}[Cjane@x.com"             "jane@x.com"
check "CSI Left alone"                              "${E}[Djane@x.com"             "jane@x.com"
check "CSI Home"                                    "${E}[Hjane@x.com"             "jane@x.com"
check "CSI End"                                     "${E}[Fjane@x.com"             "jane@x.com"
check "CSI Ctrl+Right (ESC[1;5C)"                   "${E}[1;5Cjohn@x.com"          "john@x.com"
check "CSI Insert key (ESC[2~)"                     "${E}[2~john@x.com"            "john@x.com"
check "CSI Delete key (ESC[3~)"                     "${E}[3~john@x.com"            "john@x.com"
check "CSI bracketed-paste start (ESC[200~)"        "${E}[200~pasted@x.com"        "pasted@x.com"
check "CSI bracketed-paste end (ESC[201~)"          "${E}[201~pasted@x.com"        "pasted@x.com"
check "CSI DEC private mode set (ESC[?25h)"         "${E}[?25hvis@x.com"           "vis@x.com"
check "CSI DEC private mode reset (ESC[?25l)"       "${E}[?25lvis@x.com"           "vis@x.com"
check "CSI ':' sub-parameter (kitty/modifyOtherKeys)" "${E}[27:5:97~weird@x.com"   "weird@x.com"
check "CSI SGR color code (ESC[38;5;196m)"          "${E}[38;5;196mcolor@x.com"    "color@x.com"
check "CSI with intermediate byte (ESC[0 q)"        "${E}[0 qjohn@x.com"           "john@x.com"
check "SS3 Up (app-keypad mode)"                    "${E}OAjane@x.com"             "jane@x.com"
check "SS3 Down"                                    "${E}OBjane@x.com"             "jane@x.com"
check "SS3 F1"                                      "${E}OPjane@x.com"             "jane@x.com"
check "SS3 F4"                                      "${E}OSjane@x.com"             "jane@x.com"
check "Focus-out report (ESC[O)"                    "${E}[Ofocused@x.com"          "focused@x.com"
check "Focus-in report (ESC[I)"                     "${E}[Ifocused@x.com"          "focused@x.com"
check "Cursor position report (ESC[24;80R)"         "${E}[24;80Rjohn@x.com"        "john@x.com"
check "Device attributes reply (ESC[?1;2c)"         "${E}[?1;2cjohn@x.com"         "john@x.com"
check "Escape sequence in the middle, not just the prefix" "abc${E}[Adef@x.com"    "abcdef@x.com"
check "Two different sequences, interleaved with text"     "ab${E}[Acd${E}OBef@x.com" "abcdef@x.com"
check "Sequence immediately followed by real digits"       "${E}[A123@x.com"       "123@x.com"

echo "strip_term_noise — unrecognized/malformed input (ESC/control byte still removed by the [:cntrl:] fallback):"
check "Lone orphan ESC, nothing after"               "${E}solo@x.com"              "solo@x.com"
check "ESC followed by an unrelated single letter"   "${E}qsolo@x.com"             "qsolo@x.com"
check "Stray BEL (ctrl-G) from a terminal beep"      $'\007beep@x.com'             "beep@x.com"
check "Stray BS (backspace byte) mid-string"         $'ab\010cd@x.com'             "abcd@x.com"
check "Stray VT/FF bytes"                            $'a\013b\014c@x.com'          "abc@x.com"
check "DEL byte (0x7F)"                              $'ab\177cd@x.com'             "abcd@x.com"
# Tab (0x09) is itself a POSIX [:cntrl:] byte. It is deliberately NOT carved out as an exception —
# doing so would mean deviating from the standard class into a one-off custom set, and nobody can
# produce a literal tab in a credential field by typing it at a terminal prompt anyway.
check "Tab — stripped like any other control byte, by design" $'a\tb'              "ab"

echo "strip_term_noise — legitimate content (must survive byte-for-byte):"
check "Plain clean email, no-op"                    "admin.user@example.com"    "admin.user@example.com"
check "Literal '[' with no ESC before it"            "abc[def]123"                 "abc[def]123"
check "Literal CSI-shaped text with no ESC at all"   "[1;5Cnotasequence"           "[1;5Cnotasequence"
check "Literal 'O'+letter with no ESC before it"     "OAnotasequence"              "OAnotasequence"
check "UTF-8 accented password"                      "pässwörd"                    "pässwörd"
check "UTF-8 emoji password"                         "sec😀ret"                    "sec😀ret"
check "Password with a heavy punctuation/symbol set" 'P@ss!#%^&*()_+-=[]{}:;<>,.?/~`' 'P@ss!#%^&*()_+-=[]{}:;<>,.?/~`'
check "Password with a literal backslash and dollar" 'p@ss\$word'                  'p@ss\$word'
check "Empty string"                                 ""                           ""
check "Interior whitespace survives"                 "a b c"                      "a b c"
check "API-key-shaped value (sk-ant-oat01-...)"      "sk-ant-oat01-ZzAc2A2fOC2V-xVOKNI0UfRk5w" "sk-ant-oat01-ZzAc2A2fOC2V-xVOKNI0UfRk5w"

t "idempotent: cleaning already-clean output changes nothing further"
once="$(strip_term_noise "${E}[A${E}[Badmin.user@example.com")"
twice="$(strip_term_noise "$once")"
if [ "$once" = "$twice" ]; then ok; else bad "once=$(printf '%q' "$once") twice=$(printf '%q' "$twice")"; fi

# Pull prompt() out the same way. These pipe input rather than driving a real pty, so they check
# sanitization, secret-vs-plain handling, and exit-status correctness — not that readline itself
# intercepts a raw escape sequence (standard GNU Readline behavior, not new logic here).
eval "$(awk '/^prompt\(\) \{/,/^}/' run.sh)"

echo "prompt() — captures a clean value and reports success:"
t "non-secret: plain piped input"
EMAIL=""; rc=0
EMAIL="$(printf 'admin.user@example.com\n' | (eval "$(awk '/^strip_term_noise\(\) \{/,/^}/' run.sh; awk '/^prompt\(\) \{/,/^}/' run.sh)"; prompt EMAIL "Admin email" >/dev/null; printf '%s' "$EMAIL"))"
if [ "$EMAIL" = "admin.user@example.com" ]; then ok; else bad "got $(printf '%q' "$EMAIL")"; fi

t "secret: plain piped input"
PW="$(printf 'Vijay123#\n' | (eval "$(awk '/^strip_term_noise\(\) \{/,/^}/' run.sh; awk '/^prompt\(\) \{/,/^}/' run.sh)"; prompt PW "Admin password" secret 2>/dev/null >/dev/null; printf '%s' "$PW"))"
if [ "$PW" = "Vijay123#" ]; then ok; else bad "got $(printf '%q' "$PW")"; fi

t "non-secret: escape-sequence-contaminated piped input still comes out clean"
EMAIL="$(printf '\033[A\033[Badmin.user@example.com\n' | (eval "$(awk '/^strip_term_noise\(\) \{/,/^}/' run.sh; awk '/^prompt\(\) \{/,/^}/' run.sh)"; prompt EMAIL "Admin email" >/dev/null; printf '%s' "$EMAIL"))"
if [ "$EMAIL" = "admin.user@example.com" ]; then ok; else bad "got $(printf '%q' "$EMAIL")"; fi

echo "prompt() — EOF is reported, in both branches (the bug a literal first draft had):"
t "non-secret: EOF yields rc=1"
rc="$( (eval "$(awk '/^strip_term_noise\(\) \{/,/^}/' run.sh; awk '/^prompt\(\) \{/,/^}/' run.sh)"; prompt V "x" < /dev/null >/dev/null 2>&1; echo $?) )"
if [ "$rc" = 1 ]; then ok; else bad "rc=$rc (expected 1)"; fi

t "secret: EOF yields rc=1, not masked by the trailing 'echo >&2'"
rc="$( (eval "$(awk '/^strip_term_noise\(\) \{/,/^}/' run.sh; awk '/^prompt\(\) \{/,/^}/' run.sh)"; prompt V "x" secret < /dev/null >/dev/null 2>&1; echo $?) )"
if [ "$rc" = 1 ]; then ok; else bad "rc=$rc (expected 1) — the echo-after-read sequencing bug is back"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
