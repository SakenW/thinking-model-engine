#!/usr/bin/env bash

# Read-only structural validation for Thinking Model Engine.
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SKILL_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
EXPECTED_MODEL_COUNT=138
FAILURES=0

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

validate_frontmatter() {
  local skill_file="$SKILL_ROOT/SKILL.md"
  local closing_line name_value description_value

  if [ "$(sed -n '1p' "$skill_file")" != '---' ]; then
    fail 'SKILL.md YAML frontmatter is missing'
    return
  fi

  closing_line="$(awk 'NR > 1 && $0 == "---" { print NR; exit }' "$skill_file")"
  if [ -z "$closing_line" ]; then
    fail 'SKILL.md YAML frontmatter is not closed'
    return
  fi

  name_value="$(sed -n "2,$((closing_line - 1))p" "$skill_file" | sed -n 's/^name:[[:space:]]*//p')"
  description_value="$(sed -n "2,$((closing_line - 1))p" "$skill_file" | sed -n 's/^description:[[:space:]]*//p')"

  if [ "$(printf '%s\n' "$name_value" | sed '/^$/d' | wc -l | tr -d ' ')" -ne 1 ] ||
     ! printf '%s' "$name_value" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'; then
    fail 'YAML name must be one non-empty lowercase kebab-case value'
  elif [ "$(trim "$description_value")" = '' ]; then
    fail 'YAML description must be one non-empty value'
  elif [ "$(printf '%s\n' "$description_value" | sed '/^$/d' | wc -l | tr -d ' ')" -ne 1 ]; then
    fail 'YAML description must appear exactly once'
  else
    pass 'SKILL.md YAML name and description'
  fi
}

validate_skill_length() {
  local lines
  lines="$(wc -l < "$SKILL_ROOT/SKILL.md" | tr -d ' ')"
  if [ "$lines" -lt 500 ]; then
    pass "SKILL.md length ${lines}/499 lines"
  else
    fail "SKILL.md has $lines lines; expected fewer than 500"
  fi
}

extract_wiki_targets() {
  perl -ne 'while (/\[\[([^\]]+)\]\]/g) { $t = $1; $t =~ s/\|.*$//; $t =~ s/[#^].*$//; $t =~ s/^\s+|\s+$//g; print "$t\n" if length $t; }' "$1"
}

validate_model_catalog() {
  local catalog="$SKILL_ROOT/models/00_目录.md"
  local model_count catalog_count duplicates missing coverage_errors target base occurrences

  model_count="$(find "$SKILL_ROOT/models" -maxdepth 1 -type f -name '思维模型 - *.md' | wc -l | tr -d ' ')"
  catalog_count="$(extract_wiki_targets "$catalog" | grep -c '^思维模型 - ' || true)"

  if [ "$model_count" -ne "$EXPECTED_MODEL_COUNT" ]; then
    fail "model file count is $model_count; expected $EXPECTED_MODEL_COUNT"
  elif [ "$model_count" -ne "$catalog_count" ]; then
    fail "model count mismatch: files=$model_count catalog_links=$catalog_count"
  else
    pass "model file count: $model_count"
  fi

  duplicates="$(extract_wiki_targets "$catalog" | sort | uniq -d)"
  if [ -n "$duplicates" ]; then
    fail "models/00_目录.md has duplicate targets: $(printf '%s' "$duplicates" | paste -sd ', ' -)"
  else
    pass 'models/00_目录.md targets are unique'
  fi

  missing=''
  while IFS= read -r target; do
    case "$target" in
      */*) base="$target" ;;
      *) base="models/$target" ;;
    esac
    case "$base" in *.md) ;; *) base="$base.md" ;; esac
    if [ ! -f "$SKILL_ROOT/$base" ]; then
      missing="${missing}${missing:+, }$target"
    fi
  done < <(extract_wiki_targets "$catalog")

  if [ -n "$missing" ]; then
    fail "models/00_目录.md has missing targets: $missing"
  else
    pass 'models/00_目录.md targets exist'
  fi

  coverage_errors=''
  while IFS= read -r model_file; do
    base="$(basename "$model_file" .md)"
    occurrences="$(extract_wiki_targets "$catalog" | grep -Fxc "$base" || true)"
    if [ "$occurrences" -ne 1 ]; then
      coverage_errors="${coverage_errors}${coverage_errors:+, }$base($occurrences)"
    fi
  done < <(find "$SKILL_ROOT/models" -maxdepth 1 -type f -name '思维模型 - *.md' | sort)

  if [ -n "$coverage_errors" ]; then
    fail "models/00_目录.md coverage errors: $coverage_errors"
  else
    pass 'models/00_目录.md covers each model exactly once'
  fi
}

wiki_target_exists() {
  local source_file="$1" target="$2" candidate source_dir basename_candidate

  target="${target%%|*}"
  target="${target%%#*}"
  target="${target%%^*}"
  target="$(trim "$target")"
  [ -n "$target" ] || return 0

  case "$target" in
    http://*|https://*|mailto:*) return 0 ;;
  esac

  candidate="$target"
  case "$candidate" in *.md) ;; *) candidate="$candidate.md" ;; esac
  source_dir="$(dirname "$source_file")"

  [ -f "$source_dir/$candidate" ] && return 0
  [ -f "$SKILL_ROOT/$candidate" ] && return 0
  [ -f "$SKILL_ROOT/models/$candidate" ] && return 0
  [ -f "$SKILL_ROOT/references/$candidate" ] && return 0

  basename_candidate="$(basename "$candidate")"
  [ -n "$(find "$SKILL_ROOT" -type f -name "$basename_candidate" -print -quit)" ]
}

validate_all_wiki_links() {
  local link_errors='' source target

  while IFS=$'\t' read -r source target; do
    if ! wiki_target_exists "$source" "$target"; then
      link_errors="${link_errors}${link_errors:+, }${source#"$SKILL_ROOT/"} -> $target"
    fi
  done < <(
    find "$SKILL_ROOT" -type f -name '*.md' -print0 |
      while IFS= read -r -d '' source; do
        perl -ne 'while (/\[\[([^\]]+)\]\]/g) { print "$ARGV\t$1\n" }' "$source"
      done
  )

  if [ -n "$link_errors" ]; then
    fail "missing local Wiki links: $link_errors"
  else
    pass 'all local Wiki links resolve'
  fi
}

validate_markdown_structure() {
  local errors='' markdown_file result

  while IFS= read -r -d '' markdown_file; do
    result="$(awk '
      BEGIN { h1 = 0; fence = "" }
      {
        line = $0
        sub(/^[[:space:]]*/, "", line)
        marker = substr(line, 1, 1)
        if (line ~ /^```/ || line ~ /^~~~/) {
          if (fence == "") fence = marker
          else if (fence == marker) fence = ""
          next
        }
        if (fence == "" && $0 ~ /^#[[:space:]]+/) h1++
      }
      END {
        if (h1 != 1 || fence != "") printf "H1=%d,fence=%s", h1, (fence == "" ? "paired" : "unclosed")
      }
    ' "$markdown_file")"
    if [ -n "$result" ]; then
      errors="${errors}${errors:+, }${markdown_file#"$SKILL_ROOT/"}($result)"
    fi
  done < <(find "$SKILL_ROOT" -type f -name '*.md' -print0)

  if [ -n "$errors" ]; then
    fail "Markdown structure: $errors"
  else
    pass 'every Markdown file has one H1 and paired fences'
  fi
}

validate_retired_names() {
  local retired
  retired="$(find "$SKILL_ROOT/models" -maxdepth 1 -type f \( -name '*莫塔5问*' -o -name '*贝勃定律*' -o -name '*远因效应*' \) -print)"
  if [ -n "$retired" ]; then
    fail "retired model filenames still exist: $(printf '%s' "$retired" | sed "s|$SKILL_ROOT/||" | paste -sd ', ' -)"
  else
    pass 'retired model filenames are absent'
  fi
}

validate_stale_counts() {
  local stale
  stale="$(grep -nE '(^|[^0-9])(119|115|117)([^0-9]|$)' "$SKILL_ROOT/SKILL.md" "$SKILL_ROOT/README.md" || true)"
  if [ -n "$stale" ]; then
    fail "SKILL.md/README.md contain stale counts 119, 115, or 117 ($(printf '%s\n' "$stale" | wc -l | tr -d ' ') matches)"
  else
    pass 'SKILL.md/README.md contain no stale model counts'
  fi
}

validate_frontmatter
validate_skill_length
validate_model_catalog
validate_all_wiki_links
validate_markdown_structure
validate_retired_names
validate_stale_counts

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS validation complete\n'
  exit 0
fi

printf 'FAIL validation complete: %d check(s) failed\n' "$FAILURES" >&2
exit 1
