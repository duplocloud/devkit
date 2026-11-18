# shellcheck shell=bash
# Sourced by scripts/build-extension.sh — the extension naming gate, kept apart so tests can call it directly.
#
# The platform shares one runtime across all extensions, so every customer-facing name MUST be namespaced under
# extensions/ (and Mongo collections under extension_). A non-conforming bundle silently collides with built-ins at
# runtime (e.g. a clouds/ FE route resolves to the built-in module → blank page). See
# .claude/skills/duplo-extension-dev/reference/00-naming.md
#
# One exception: an extension that takes over an existing built-in feature keeps that feature's customer URLs and
# collections, declared in its manifest as  "naming": { "legacy": true, "reason": "<why>" }. That skips only the
# namespacing rules, needs a reason, and prints it on every build.

# naming_gate DIR MANIFEST — prints ✗ lines to stderr; returns 1 when any rule is violated.
naming_gate() {
  local DIR="$1" MANIFEST="$2" viol=0 legacy reason seg p u m name r bad fe_segs nres want hits
  legacy=$(jq -r '.naming.legacy // false' "$MANIFEST")
  if [ "$legacy" = true ]; then
    reason=$(jq -r '.naming.reason // ""' "$MANIFEST")
    if [ -z "${reason//[[:space:]]/}" ]; then
      echo "  ✗ naming.legacy is true but naming.reason is empty — say why this extension keeps pre-extension names" >&2
      viol=1
    else
      echo "    naming.legacy: $reason (extensions/ and extension_ namespacing skipped)"
    fi
  else
    # Top-level resources must namespace their own restSegment. A nested child (has a `parent` block) is exempt: its
    # restSegment is a leaf and the namespacing comes from parent.routeSegment (checked below) — its route is
    # …/extensions/<parent>/{parentId}/<leaf>.
    while IFS= read -r seg; do
      case "$seg" in extensions/*) ;; "") ;; *)
        echo "  ✗ resources[].restSegment '$seg' must start with 'extensions/' (e.g. extensions/$seg)" >&2; viol=1 ;;
      esac
    done < <(jq -r '.resources[]? | select(.parent == null) | .restSegment // empty' "$MANIFEST")
    while IFS= read -r seg; do
      case "$seg" in extensions/*) ;; "") ;; *)
        echo "  ✗ resources[].parent.routeSegment '$seg' must start with 'extensions/' (match the parent's restSegment)" >&2; viol=1 ;;
      esac
    done < <(jq -r '.resources[]?.parent?.routeSegment // empty' "$MANIFEST")
    while IFS= read -r p; do
      case "$p" in extensions/*) ;; "") ;; *)
        echo "  ✗ frontend.routes[].path '$p' must start with 'extensions/' (never 'clouds/')" >&2; viol=1 ;;
      esac
    done < <(jq -r '.frontend.routes[]?.path // empty' "$MANIFEST")
    while IFS= read -r u; do
      case "$u" in extensions/*) ;; "") ;; *)
        echo "  ✗ frontend.menus relativeUrl '$u' must start with 'extensions/' (never 'clouds/')" >&2; viol=1 ;;
      esac
    done < <(jq -r '.frontend.menus // [] | .. | objects | .relativeUrl? // empty' "$MANIFEST")
    while IFS= read -r m; do
      name=$(printf '%s' "$m" | sed -E 's/.*BsonCollection\("([^"]*)".*/\1/')
      case "$name" in extension_*) ;; *)
        echo "  ✗ [BsonCollection(\"$name\")] must be prefixed 'extension_' (e.g. extension_$name)" >&2; viol=1 ;;
      esac
    done < <(grep -rhoE 'BsonCollection\("[^"]*"\)' "$DIR/backend" 2>/dev/null || true)
    while IFS= read -r r; do
      printf '%s' "$r" | grep -qE 'environment/(extensions/|extension-studio)' && continue
      echo "  ✗ controller route not under 'environment/extensions/': $r" >&2; viol=1
    done < <(grep -rhoE 'Route\("[^"]*environment/[^"]*"\)' "$DIR/backend" 2>/dev/null || true)
    if [ -d "$DIR/skills" ]; then
      bad=$(grep -rnE 'environment/[a-z0-9-]+' "$DIR/skills" 2>/dev/null \
            | grep -vE 'environment/(extensions/|extension-studio)' | grep -vE 'environment/\{' || true)
      [ -n "$bad" ] && { echo "  ! skill callback URL(s) not under 'environment/extensions/' — confirm they target this extension's restSegment:" >&2; printf '%s\n' "$bad" | sed 's/^/      /' >&2; }
    fi
    # Frontend ↔ backend route parity: the FE service builds its data URL from REST_SEGMENT, which MUST be the full
    # 'extensions/<…>' path AND (for a single top-level resource) equal the manifest restSegment. A bare leaf 404s
    # every list/get/create/view-template call — the #1 scaffolding pitfall. See reference/00-naming.md.
    if [ -d "$DIR/frontend/src" ]; then
      fe_segs=$(grep -rhoE "REST_SEGMENT[[:space:]]*=[[:space:]]*'[^']+'" "$DIR/frontend/src" 2>/dev/null \
                | sed -E "s/.*'([^']+)'.*/\1/" | sort -u)
      while IFS= read -r seg; do
        [ -n "$seg" ] || continue
        case "$seg" in extensions/*) ;; *)
          echo "  ✗ frontend REST_SEGMENT '$seg' must be the full 'extensions/<…>' path (== manifest restSegment), not a bare leaf — it 404s" >&2; viol=1 ;;
        esac
      done <<EOF
$fe_segs
EOF
      nres=$(jq -r '[.resources[]? | select(.parent == null)] | length' "$MANIFEST")
      if [ "$nres" = "1" ] && [ -n "$fe_segs" ]; then
        want=$(jq -r '[.resources[]? | select(.parent == null)][0].restSegment' "$MANIFEST")
        while IFS= read -r seg; do
          [ -n "$seg" ] || continue
          [ "$seg" = "$want" ] || { echo "  ✗ frontend REST_SEGMENT '$seg' != manifest restSegment '$want' (they must be identical)" >&2; viol=1; }
        done <<EOF
$fe_segs
EOF
      fi
    fi
  fi

  if jq -e '.frontend.menu' "$MANIFEST" >/dev/null 2>&1; then
    echo "  ✗ legacy 'frontend.menu' is deprecated — use the 'frontend.menus' array" >&2; viol=1
  fi
  # No leftover template identifiers in a renamed extension. Samples/templates may keep 'Hello' names (reference
  # code), but a real extension under extensions/<name>/ must rename the FE off the template (see the FE rename
  # table in reference/02-authoring-guide.md).
  case "$DIR" in
    *samples/*|*templates/*) ;;
    *)
      if [ -d "$DIR/frontend/src" ]; then
        hits=$(grep -rnE 'HelloService|HelloWorld|hw-(add|list|view|root)|hello\.service' "$DIR/frontend/src" 2>/dev/null || true)
        if [ -n "$hits" ]; then
          echo "  ✗ frontend still has template 'Hello'/'hw-' identifiers — rename them to your resource:" >&2
          printf '%s\n' "$hits" | head -8 | sed 's/^/      /' >&2; viol=1
        fi
      fi ;;
  esac

  return $viol
}
