#!/usr/bin/env bash
# Check apple/bridge/ui-commands.txt against the engine catalog and the Swift sources.
#  1. every id in ui-commands.txt exists in the engine catalog;
#  2. every command-id literal in apple/FigCraft/**/*.swift (run("id"), present("id"), isEnabled("id"),
#     disabledReason("id"), execute("id"), "command.<id>"; `command.sheet.*` are widget ids, ignored) is
#     listed in ui-commands.txt;
#  3. widget identifiers (accessibilityIdentifier("panel.layers"), ...) must not be command ids: only
#     `command.<id>` may carry a command id.
# Exit 1 on any problem. Needs cargo, bash, grep.
set -euo pipefail
APPLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST="$APPLE/bridge/ui-commands.txt"
SRC="$APPLE/FigCraft"
HERE="$APPLE/scripts"
[[ -f "$LIST" ]] || { echo "error: $LIST not found" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

"$HERE/dump-catalog.sh" engine | cut -f1 | sort -u > "$TMP/catalog.txt"
sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$LIST" | grep -v '^$' | sort -u > "$TMP/known.txt" || true
status=0

comm -23 "$TMP/known.txt" "$TMP/catalog.txt" > "$TMP/unknown.txt"
if [[ -s "$TMP/unknown.txt" ]]; then
  echo "error: ids in ui-commands.txt that are not engine commands:" >&2
  sed 's/^/  /' "$TMP/unknown.txt" >&2; status=1
fi

if [[ -d "$SRC" ]]; then
  # id<TAB>file:line
  find "$SRC" -name '*.swift' -type f -print0 | sort -z | xargs -0 grep -nHoE \
    '(run|present|isEnabled|disabledReason|execute)\(\s*"[A-Za-z0-9.]+"|"command\.[A-Za-z0-9.]+"' 2>/dev/null \
    | sed -E 's/^([^:]+):([0-9]+):.*"([A-Za-z0-9.]+)"$/\3\t\1:\2/; s/^command\.//' \
    | grep -E '^[A-Za-z]+(\.[A-Za-z0-9]+)+'$'\t' | sed -E 's/^command\.//' | grep -v $'^sheet\\.' | sort > "$TMP/used.txt" || true
  cut -f1 "$TMP/used.txt" | sort -u > "$TMP/used-ids.txt"
  comm -23 "$TMP/used-ids.txt" "$TMP/known.txt" > "$TMP/missing.txt"
  if [[ -s "$TMP/missing.txt" ]]; then
    echo "error: command ids used in Swift but missing from apple/bridge/ui-commands.txt:" >&2
    while read -r id; do
      where="$(grep -F "$id"$'\t' "$TMP/used.txt" | cut -f2 | head -3 | tr '\n' ' ')"
      known=""; grep -qxF "$id" "$TMP/catalog.txt" || known="  [not an engine command: typo?]"
      echo "  $id   ($where)$known" >&2
    done < "$TMP/missing.txt"
    status=1
  fi
  # Widget identifiers that collide with command ids.
  find "$SRC" -name '*.swift' -type f -print0 | sort -z | xargs -0 grep -nHoE \
    'accessibilityIdentifier\(\s*"[A-Za-z0-9.]+"' 2>/dev/null \
    | sed -E 's/^([^:]+):([0-9]+):.*"([A-Za-z0-9.]+)"$/\3\t\1:\2/' | sort > "$TMP/widgets.txt" || true
  cut -f1 "$TMP/widgets.txt" | sort -u | comm -12 - "$TMP/catalog.txt" > "$TMP/clash.txt"
  if [[ -s "$TMP/clash.txt" ]]; then
    echo "error: widget accessibility identifiers that are also command ids (use command.<id> for commands):" >&2
    while read -r id; do
      echo "  $id   ($(grep -F "$id"$'\t' "$TMP/widgets.txt" | cut -f2 | head -3 | tr '\n' ' '))" >&2
    done < "$TMP/clash.txt"
    status=1
  fi
  echo "check-command-ids: $(wc -l < "$TMP/known.txt" | tr -d ' ') listed, $(wc -l < "$TMP/used-ids.txt" | tr -d ' ') used in Swift"
else
  echo "check-command-ids: $SRC does not exist, Swift check skipped"
fi
[[ $status == 0 ]] && echo "check-command-ids: OK"
exit $status
