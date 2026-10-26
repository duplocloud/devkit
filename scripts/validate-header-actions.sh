#!/usr/bin/env bash
# Build-time twin of the portal's header-action-registry: any entry the portal would drop fails the build.
# Source it and call `validate_header_actions <manifest.json>`, or run it with a manifest path.

_HA_JQ='
def isnb: type == "string" and (gsub("^\\s+|\\s+$"; "") | length > 0);
def isflag: type == "boolean";
def safeurl:
  type == "string" and startswith("/v1/aiservicedesk/")
  and (split("?")[0] as $p
       | ($p | contains("//") | not) and ($p | contains("\\") | not)
       and ($p | split("/") | map(gsub("%2e"; "."; "i")) | any(. == "." or . == "..") | not));
def goodshortcut:
  type == "string" and (contains("\n") | not)
  and (split("+")[-1] | IN("Mod", "Ctrl", "Shift", "Alt") | not)
  and test("^((Mod|Ctrl|Shift|Alt)\\+)+([A-Z][A-Za-z0-9]+)$")
  and (split("+")[:-1] as $m
       | (($m | unique | length) == ($m | length)) and (($m | index("Mod")) != null and ($m | index("Ctrl")) != null | not));

def entry($p; $child):
  if type != "object" then "\($p): entry is not an object"
  else
    . as $e
    | (if (.id | isnb | not) then "\($p).id: must be a non-blank string" else empty end),
      (if (.label | isnb | not) then "\($p).label: must be a non-blank string" else empty end),
      (if has("order") and (.order | (type == "number") | not) then "\($p).order: must be a finite number" else empty end),
      (if has("roles") and ((.roles | type) != "array" or (.roles | all(type == "string") | not)) then "\($p).roles: must be an array of strings" else empty end),
      (("showInAdmin", "isolatePointer", "preserveFocus") as $f
        | if ($e | has($f)) and ($e[$f] | isflag | not) then "\($p).\($f): must be a boolean" else empty end),
      (if has("matIcon") and (.matIcon | isnb | not) then "\($p).matIcon: must be a non-blank string" else empty end),
      (if has("placement") and (.placement != "inline" and .placement != "menu") then "\($p).placement: must be inline or menu" else empty end),
      (if $child then (("children", "placement", "showInAdmin") as $k
        | if ($e | has($k)) then "\($p).\($k): a child must not set \($k)" else empty end) else empty end),
      (if has("children") then
         ((("expose", "shortcut", "visibilityUrl", "isolatePointer", "preserveFocus") as $k
           | if ($e | has($k)) then "\($p).\($k): a group must not set \($k)" else empty end),
          (if ($child | not) and (.matIcon | isnb | not) then "\($p).matIcon: top-level entry needs matIcon" else empty end),
          (if (.children | type) != "array" or (.children | length) == 0 then "\($p).children: must be a non-empty array"
           else (.children | to_entries[] | . as $c | $c.value | entry("\($p).children[\($c.key)]"; true)) end))
       else
         ((if (.expose | isnb | not) then "\($p).expose: action needs an expose" else empty end),
          (if has("visibilityUrl") and (.visibilityUrl | safeurl | not) then "\($p).visibilityUrl: must be a /v1/aiservicedesk/ path without //, \\, scheme or dot segments" else empty end),
          (if has("shortcut") and (.shortcut | goodshortcut | not) then "\($p).shortcut: unparseable (use e.g. Mod+Shift+Period)" else empty end),
          (if ($child | not) and (.matIcon | isnb | not) then "\($p).matIcon: top-level entry needs matIcon" else empty end))
       end)
  end;
'

validate_header_actions() {
  local manifest="$1" out
  if ! jq -e . "$manifest" >/dev/null 2>&1; then
    echo "  ✗ frontend.headerActions: manifest is not valid JSON" >&2; return 1
  fi
  out=$(jq -r "$_HA_JQ"'
    (if (.frontend | type) == "object" and (.frontend | has("headerActions")) then .frontend.headerActions else null end) as $h
    | if $h == null then empty
      elif ($h | type) != "array" then "frontend.headerActions: must be an array"
      else
        ($h | to_entries[] | . as $t | $t.value | entry("frontend.headerActions[\($t.key)]"; false)),
        ([ $h[] | select(type == "object") | (.id, ((.children // []) | if type == "array" then .[] | select(type == "object") | .id else empty end)) | select(isnb) ]
          | group_by(.)[] | select(length > 1) | "frontend.headerActions: duplicate id \"\(.[0])\"")
      end' "$manifest") || { echo "  ✗ frontend.headerActions: could not be evaluated" >&2; return 1; }
  [ -z "$out" ] && return 0
  printf '%s\n' "$out" | sed 's/^/  ✗ /' >&2
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  validate_header_actions "${1:?usage: validate-header-actions.sh <manifest.json>}"
fi
