#!/usr/bin/env bash
# Unit tests for _metrics-log.csv v1.0.0 → v1.1.0 migration (IMPL-25-03).
#
# Validates the three AC items for US-E02-002:
#   1. New file receives v1.1.0 header on first append.
#   2. Existing v1.0.0 file is migrated: old rows preserved, header upgraded.
#   3. Migration is idempotent (re-running does not duplicate the header).
#   4. Null token fields render as "tokens unavailable" in the markdown report.
#
# Calls the Python module directly; no hook payload scaffolding needed.
# CC conventions validated: CC-02.4.2 (null-safe), CC-04.6 (schema versioning)

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

REPO_ROOT="$(repo_root)"
SCRIPT="$REPO_ROOT/scripts/metrics_collector.py"

# ---------------------------------------------------------------------------
# Helpers — invoke the schema-migration helpers directly via Python
# ---------------------------------------------------------------------------

_py() {
    python3 - "$@" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import metrics_collector as mc
from pathlib import Path
cmd = sys.argv[2]

if cmd == "append_row":
    csv_path = Path(sys.argv[3])
    mc._append_csv_row(
        csv_path,
        work_item_id="TEST-001",
        round_label="0",
        generated_at="2026-05-20 10:00 UTC",
        aggregates={
            "cycle_time_minutes": 42,
            "p3_duration_minutes": 30,
            "p5_duration_minutes": 10,
            "p7_duration_minutes": 5,
            "reviewer_rework_rounds": 2,
            "pr_review_rounds": 1,
            "coverage_pct": 91.5,
            "defect_escape_count": 0,
            # token fields intentionally absent (null)
            "tokens_input": "",
            "tokens_output": "",
            "tokens_cache_read": "",
            "tokens_cache_write": "",
            "mode": "full",
        },
    )

elif cmd == "migrate":
    mc._migrate_csv_if_needed(Path(sys.argv[3]))

elif cmd == "read_header":
    import csv
    with open(sys.argv[3], newline="") as f:
        reader = csv.DictReader(f)
        print(",".join(reader.fieldnames or []))

elif cmd == "count_rows":
    import csv
    with open(sys.argv[3], newline="") as f:
        rows = list(csv.DictReader(f))
    print(len(rows))

elif cmd == "get_field":
    import csv
    row_idx = int(sys.argv[4])
    field = sys.argv[5]
    with open(sys.argv[3], newline="") as f:
        rows = list(csv.DictReader(f))
    print(rows[row_idx].get(field, "__MISSING__"))

elif cmd == "render_tokens":
    # Render a report and check the token section output.
    import io, csv
    agg = {
        "cycle_time_minutes": 42,
        "p3_duration_minutes": None,
        "p5_duration_minutes": None,
        "p7_duration_minutes": None,
        "reviewer_rework_rounds": 1,
        "pr_review_rounds": 1,
        "coverage_pct": None,
        "defect_escape_count": 0,
        "tokens_input": "",
        "tokens_output": "",
        "tokens_cache_read": "",
        "tokens_cache_write": "",
        "mode": "full",
    }
    report = mc._render_report(
        workflow_dir=Path("."),
        work_item_id="TEST-001",
        round_label="0",
        workflow_metrics={},
        tasks=[],
        aggregates=agg,
        generated_at="2026-05-20 10:00 UTC",
    )
    print(report)
PYEOF
}

V1_0_HEADER="schema_version,work_item_id,round,timestamp_utc,cycle_time_minutes,p3_duration_minutes,p5_duration_minutes,p7_duration_minutes,reviewer_rework_rounds,pr_review_rounds,coverage_pct,defect_escape_count"
V1_1_EXPECTED_COLS="tokens_input,tokens_output,tokens_cache_read,tokens_cache_write,mode"

# ---------------------------------------------------------------------------
# Test 1: new file gets v1.1.0 header on first append
# ---------------------------------------------------------------------------

test_new_file_gets_v110_header() {
    local csv
    csv="$FAKE_WORKSPACE/_metrics-log.csv"
    _py "$REPO_ROOT/scripts" append_row "$csv" 2>/dev/null || true
    [ -f "$csv" ] || { _fail "CSV file not created"; return; }
    local header
    header="$(_py "$REPO_ROOT/scripts" read_header "$csv")"
    for col in tokens_input tokens_output tokens_cache_read tokens_cache_write mode; do
        if ! printf '%s' "$header" | grep -qF "$col"; then
            _fail "new-file header missing column '$col' (got: $header)"
            return
        fi
    done
    # schema_version column must be present
    printf '%s' "$header" | grep -qF "schema_version" || {
        _fail "new-file header missing schema_version"
        return
    }
}

# ---------------------------------------------------------------------------
# Test 2: v1.0.0 file is migrated — old rows preserved, new header written
# ---------------------------------------------------------------------------

test_v100_file_migrated_old_rows_preserved() {
    local csv
    csv="$FAKE_WORKSPACE/_metrics-log-v10.csv"
    # Write a synthetic v1.0.0 file with one row
    printf '%s\n' "$V1_0_HEADER" > "$csv"
    printf '1.0.0,STORY-42,0,2026-01-01 09:00 UTC,60,40,15,5,2,1,88.0,0\n' >> "$csv"

    _py "$REPO_ROOT/scripts" append_row "$csv" 2>/dev/null || true

    # Header must now contain v1.1.0 columns
    local header
    header="$(_py "$REPO_ROOT/scripts" read_header "$csv")"
    for col in tokens_input mode; do
        printf '%s' "$header" | grep -qF "$col" || {
            _fail "migrated header missing '$col'"
            return
        }
    done

    # Old row must still be present (row 0 = the original v1.0 row)
    local old_id
    old_id="$(_py "$REPO_ROOT/scripts" get_field "$csv" 0 work_item_id)"
    [ "$old_id" = "STORY-42" ] || {
        _fail "old row not preserved after migration (got work_item_id='$old_id')"
        return
    }

    # Old row schema_version must remain "1.0.0" (not overwritten)
    local old_ver
    old_ver="$(_py "$REPO_ROOT/scripts" get_field "$csv" 0 schema_version)"
    [ "$old_ver" = "1.0.0" ] || {
        _fail "old row schema_version must stay '1.0.0', got '$old_ver'"
        return
    }

    # New row (row 1) must be schema_version 1.1.0
    local new_ver
    new_ver="$(_py "$REPO_ROOT/scripts" get_field "$csv" 1 schema_version)"
    [ "$new_ver" = "1.1.0" ] || {
        _fail "new row schema_version should be '1.1.0', got '$new_ver'"
    }
}

# ---------------------------------------------------------------------------
# Test 3: migration is idempotent — running again does not duplicate header
# ---------------------------------------------------------------------------

test_migration_is_idempotent() {
    local csv
    csv="$FAKE_WORKSPACE/_metrics-log-idem.csv"
    printf '%s\n' "$V1_0_HEADER" > "$csv"
    printf '1.0.0,STORY-99,0,2026-01-01 09:00 UTC,60,40,15,5,2,1,90.0,0\n' >> "$csv"

    # Migrate twice
    _py "$REPO_ROOT/scripts" migrate "$csv" 2>/dev/null || true
    _py "$REPO_ROOT/scripts" migrate "$csv" 2>/dev/null || true

    # Row count must still be 1 (not 2)
    local count
    count="$(_py "$REPO_ROOT/scripts" count_rows "$csv")"
    [ "$count" = "1" ] || _fail "expected 1 row after double migration, got $count"
}

# ---------------------------------------------------------------------------
# Test 4: null token fields render as "tokens unavailable" in the report
# ---------------------------------------------------------------------------

test_null_tokens_render_as_unavailable() {
    local report
    report="$(_py "$REPO_ROOT/scripts" render_tokens 2>/dev/null)"
    if ! printf '%s' "$report" | grep -qF "tokens unavailable"; then
        _fail "report does not contain 'tokens unavailable' for empty token fields"
        return
    fi
    # Must NOT contain " 0 " as a token value (null ≠ zero per CC-02.4.2)
    if printf '%s' "$report" | grep -E "tokens.*(input|output|cache_read|cache_write).*\| 0 " | grep -q .; then
        _fail "report renders null token as '0' — must use 'tokens unavailable'"
    fi
}

run_all_tests
