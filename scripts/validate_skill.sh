#!/usr/bin/env bash

# Read-only structural validation for Thinking Model Engine.
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SKILL_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
EXPECTED_MODEL_COUNT=140
LEGACY_EXEMPTION_COUNT=138
LEGACY_EXEMPTION_SHA256='ab998a05851e0e80c0edde2ba56f5bae8c64a7069e10e631e17a2e7091e8807a'
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

has_source_section() {
  grep -Eq '^## (依据与参考|参考书目)([[:space:]]|$)' "$1"
}

has_any_evidence_level() {
  grep -Eq '^>[[:space:]]+\*\*证据层级：[^*]+\*\*' "$1"
}

has_eligible_evidence_level_content() {
  local content="$1" declarations label

  declarations="$(printf '%s\n' "$content" | grep -E '^>[[:space:]]+\*\*证据层级：[^*]+\*\*' || true)"
  if [ "$(printf '%s\n' "$declarations" | sed '/^$/d' | wc -l | tr -d ' ')" -ne 1 ]; then
    return 1
  fi
  if printf '%s\n' "$declarations" | grep -q '来源待核验'; then
    return 1
  fi

  label="$(printf '%s\n' "$declarations" | sed -n 's/^>[[:space:]]*\*\*证据层级：\([^*]*\)\*\*.*/\1/p')"
  case "$label" in
    A|A（*|A\ \(*|A，*|A,*|A：*|A:*) return 0 ;;
    B|B（*|B\ \(*|B，*|B,*|B：*|B:*) return 0 ;;
    *) return 1 ;;
  esac
}

has_verifiable_source_content() {
  printf '%s\n' "$1" | awk '
    BEGIN { in_sources = 0; found = 0 }
    /^## (依据与参考|参考书目)([[:space:]]|$)/ { in_sources = 1; next }
    in_sources && /^##[[:space:]]/ { in_sources = 0 }
    in_sources {
      lower = tolower($0)
      if (lower ~ /https?:\/\/[^[:space:])>]+/ ||
          lower ~ /10\.[0-9][0-9][0-9][0-9][0-9]*\/[^[:space:]]+/ ||
          $0 ~ /ISBN[-:[:space:]]+[0-9Xx][0-9Xx -]*[0-9Xx]/) found = 1
    }
    END { exit(found ? 0 : 1) }
  '
}

is_fully_governed_content() {
  has_eligible_evidence_level_content "$1" && has_verifiable_source_content "$1"
}

is_fully_governed() {
  local content
  content="$(cat "$1")"
  is_fully_governed_content "$content"
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  else
    sha256sum | awk '{ print $1 }'
  fi
}

validate_evidence_policy_self_tests() {
  local valid no_level c_level source_pending empty_sources swapped_entries swapped_hash

  valid=$'# Fixture\n\n> **证据层级：A（理论）。** 可核验。\n\n## 依据与参考\n\n- [Source](https://example.com/paper)'
  no_level=$'# Fixture\n\n## 依据与参考\n\n- [Source](https://example.com/paper)'
  c_level=$'# Fixture\n\n> **证据层级：C，来源待核验。** 仅作启发。\n\n## 依据与参考\n\n- [Source](https://example.com/paper)'
  source_pending=$'# Fixture\n\n> **证据层级：A（理论，来源待核验）。** 尚未核验。\n\n## 依据与参考\n\n- [Source](https://example.com/paper)'
  empty_sources=$'# Fixture\n\n> **证据层级：A（理论）。** 可核验。\n\n## 依据与参考\n\n## 下一节\n\n无来源。'

  if ! is_fully_governed_content "$valid"; then
    fail 'evidence policy self-test rejected a valid A-level sourced model'
  elif is_fully_governed_content "$no_level"; then
    fail 'evidence policy self-test accepted a model without evidence level'
  elif is_fully_governed_content "$c_level"; then
    fail 'evidence policy self-test accepted C-level evidence'
  elif is_fully_governed_content "$source_pending"; then
    fail 'evidence policy self-test accepted source-pending evidence'
  elif is_fully_governed_content "$empty_sources"; then
    fail 'evidence policy self-test accepted an empty source section'
  else
    pass 'evidence policy rejects missing level, C-level, source-pending, and empty sources'
  fi

  swapped_entries="$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$SKILL_ROOT/references/legacy-evidence-debt.txt" | sed '1s/10-10-10/11-10-10/')"
  swapped_hash="$(printf '%s\n' "$swapped_entries" | sha256_text)"
  if [ "$swapped_hash" = "$LEGACY_EXEMPTION_SHA256" ]; then
    fail 'frozen legacy exemption self-test did not detect an identity swap'
  else
    pass 'frozen legacy exemption fingerprint rejects identity swaps'
  fi
}

validate_evidence_governance() {
  local baseline="$SKILL_ROOT/references/legacy-evidence-debt.txt"
  local baseline_entries baseline_sorted baseline_hash actual_debt model_file base
  local duplicate_entries unsorted_entries unexempted_debt
  local model_count debt_count fully_governed source_only classified_only neither incomplete_both
  local baseline_count has_source_section_marker has_level_marker paid_down

  if [ ! -f "$baseline" ]; then
    fail 'frozen legacy evidence exemption list is missing'
    return
  fi

  baseline_entries="$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$baseline")"
  baseline_sorted="$(printf '%s\n' "$baseline_entries" | LC_ALL=C sort)"
  duplicate_entries="$(printf '%s\n' "$baseline_entries" | LC_ALL=C sort | uniq -d)"
  unsorted_entries=''

  if [ "$baseline_entries" != "$baseline_sorted" ]; then
    unsorted_entries='yes'
  fi

  if [ -n "$duplicate_entries" ]; then
    fail "frozen legacy exemption list has duplicates: $(printf '%s' "$duplicate_entries" | paste -sd ', ' -)"
  elif [ -n "$unsorted_entries" ]; then
    fail 'frozen legacy exemption list must be sorted by basename'
  else
    pass 'frozen legacy exemption list is sorted and unique'
  fi

  baseline_count="$(printf '%s\n' "$baseline_entries" | wc -l | tr -d ' ')"
  baseline_hash="$(printf '%s\n' "$baseline_entries" | sha256_text)"
  if [ "$baseline_count" -ne "$LEGACY_EXEMPTION_COUNT" ]; then
    fail "frozen legacy exemption count is $baseline_count; expected $LEGACY_EXEMPTION_COUNT"
  elif [ "$baseline_hash" != "$LEGACY_EXEMPTION_SHA256" ]; then
    fail "frozen legacy exemption fingerprint changed: $baseline_hash"
  else
    pass "frozen legacy exemption identity: count=$baseline_count sha256=$baseline_hash"
  fi

  while IFS= read -r base; do
    [ -n "$base" ] || continue
    case "$base" in
      '思维模型 - '*) ;;
      *)
        fail "frozen legacy exemption list has invalid basename: $base"
        ;;
    esac
  done <<< "$baseline_entries"

  actual_debt=''
  while IFS= read -r model_file; do
    if ! is_fully_governed "$model_file"; then
      base="$(basename "$model_file" .md)"
      actual_debt="${actual_debt}${actual_debt:+$'\n'}$base"
    fi
  done < <(find "$SKILL_ROOT/models" -maxdepth 1 -type f -name '思维模型 - *.md' | LC_ALL=C sort)

  unexempted_debt="$(comm -13 <(printf '%s\n' "$baseline_sorted") <(printf '%s\n' "$actual_debt" | LC_ALL=C sort))"

  if [ -n "$unexempted_debt" ]; then
    fail "evidence debt is outside the frozen legacy exemption list: $(printf '%s' "$unexempted_debt" | paste -sd ', ' -)"
  else
    pass 'actual evidence debt is a subset of the frozen legacy exemption identities'
  fi

  model_count=0
  debt_count=0
  fully_governed=0
  source_only=0
  classified_only=0
  neither=0
  incomplete_both=0
  while IFS= read -r model_file; do
    model_count=$((model_count + 1))
    if is_fully_governed "$model_file"; then
      fully_governed=$((fully_governed + 1))
      continue
    fi

    debt_count=$((debt_count + 1))
    has_source_section_marker=0
    has_level_marker=0
    has_source_section "$model_file" && has_source_section_marker=1
    has_any_evidence_level "$model_file" && has_level_marker=1
    if [ "$has_source_section_marker" -eq 1 ] && [ "$has_level_marker" -eq 1 ]; then
      incomplete_both=$((incomplete_both + 1))
    elif [ "$has_source_section_marker" -eq 1 ]; then
      source_only=$((source_only + 1))
    elif [ "$has_level_marker" -eq 1 ]; then
      classified_only=$((classified_only + 1))
    else
      neither=$((neither + 1))
    fi
  done < <(find "$SKILL_ROOT/models" -maxdepth 1 -type f -name '思维模型 - *.md' | LC_ALL=C sort)
  paid_down=$((LEGACY_EXEMPTION_COUNT - debt_count))

  if [ "$model_count" -ne "$EXPECTED_MODEL_COUNT" ]; then
    fail "evidence governance scanned $model_count models; expected $EXPECTED_MODEL_COUNT"
  else
    pass "evidence governance: fully_governed=$fully_governed legacy_debt=$debt_count paid_down=$paid_down (source_only=$source_only classified_only=$classified_only neither=$neither incomplete_both=$incomplete_both)"
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
validate_evidence_policy_self_tests
validate_evidence_governance
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
