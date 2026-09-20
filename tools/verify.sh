#!/bin/sh
# Copyright (C) 2026 Zac Sweers
# SPDX-License-Identifier: Apache-2.0
#
# verify.sh - single verify entry point shared by local development and CI.
# See VERIFYING.md for modes, caching, and failure diagnosis.

set -u

MODE=quick
OFFLINE=0

usage() {
  cat <<'USAGE'
Usage: sh tools/verify.sh [--quick | --full] [--offline]

  --quick    Fast verification (default). Toolchain checks, per-module tests in
             dependency order, compiler-plugin golden/generated-source checks
             (including a real Kotlin compilation test), publishing metadata and
             archive hygiene.
  --full     Everything in --quick, plus a full `build` and the Kotlin/KSP
             version matrix declared in compiler-version-aliases.txt, plus the
             R8 tests.
  --offline  Replay without network access. Requires a previously warmed Gradle
             cache (run once without --offline first).

Environment:
  MOSHIX_VERIFY_KOTLIN_VERSIONS  Space-separated Kotlin versions overriding
                                 compiler-version-aliases.txt in --full mode.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --quick) MODE=quick ;;
    --full) MODE=full ;;
    --offline) OFFLINE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[verify] unknown argument: $arg" >&2; usage >&2; exit 64 ;;
  esac
done

# Resolve the repo root from the script location. The canonical invocation is
# from the repo root: sh tools/verify.sh --quick
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$ROOT" || exit 1

if [ ! -f settings.gradle.kts ] || [ ! -f gradlew ]; then
  echo "[verify] error: repository root not found (settings.gradle.kts/gradlew missing)" >&2
  exit 2
fi

log() { echo "[verify] $*"; }

GRADLE_FLAGS="--console=plain -Dorg.gradle.java.installations.auto-download=false"
if [ "$OFFLINE" -eq 1 ]; then
  GRADLE_FLAGS="$GRADLE_FLAGS --offline"
fi

SUMMARY=""
FAILED_PHASE=""
PHASE_RC=0

record() { # name status seconds
  SUMMARY="${SUMMARY}$1|$2|$3
"
}

now() { date +%s; }

run_gradle() {
  # shellcheck disable=SC2086
  ./gradlew $GRADLE_FLAGS "$@"
  return $?
}

run_phase() { # name gradle-args...
  name=$1
  shift
  log "== phase: $name"
  log "   ./gradlew $*"
  start=$(now)
  run_gradle "$@"
  rc=$?
  end=$(now)
  if [ "$rc" -ne 0 ]; then
    record "$name" "FAIL" "$((end - start))"
    FAILED_PHASE=$name
    PHASE_RC=$rc
    return 1
  fi
  record "$name" "PASS" "$((end - start))"
  return 0
}

print_summary() {
  log "==================== phase summary ===================="
  echo "$SUMMARY" | while IFS='|' read -r pname pstatus pdur; do
    [ -n "$pname" ] && printf '[verify] %-4s  %-44s %ss\n' "$pstatus" "$pname" "$pdur"
  done
  if [ "$OFFLINE" -eq 1 ]; then
    log "mode=$MODE offline=yes"
  else
    log "mode=$MODE offline=no"
  fi
}

fail() {
  print_summary
  log "FAILED in phase '$FAILED_PHASE' (exit code $PHASE_RC)."
  log "Test reports: */build/reports/tests, JUnit XML: */build/test-results"
  exit "$PHASE_RC"
}

# ---------------------------------------------------------------------------
# Toolchain checks (run before any compilation)
# ---------------------------------------------------------------------------

java_major_of() { # path-to-java -> prints major version on stdout
  [ -x "$1" ] || return 1
  jv=$("$1" -version 2>&1 | head -n 1 | sed -n 's/.*version "\([^"]*\)".*/\1/p')
  [ -n "$jv" ] || return 1
  jv=${jv#1.}
  echo "${jv%%.*}"
}

check_toolchain() {
  start=$(now)
  expected_jdk=$(sed -n 's/^jdk[ ]*=[ ]*"\([^"]*\)".*/\1/p' gradle/libs.versions.toml | head -n 1)
  expected_gradle=$(sed -E -n 's/.*gradle-([0-9][0-9.]*)-(bin|all)\.zip.*/\1/p' \
    gradle/wrapper/gradle-wrapper.properties | head -n 1)

  if [ -z "$expected_jdk" ] || [ -z "$expected_gradle" ]; then
    log "[toolchain] FAIL: could not parse expected JDK/Gradle versions"
    log "  gradle/libs.versions.toml jdk='$expected_jdk', wrapper gradle='$expected_gradle'"
    record "toolchain" "FAIL" "0"
    FAILED_PHASE=toolchain
    PHASE_RC=2
    return 1
  fi

  # Collect candidate java binaries: JAVA_HOME, PATH, and any JDK locations
  # declared to Gradle via gradle.properties (no network provisioning allowed).
  candidates=""
  [ -n "${JAVA_HOME:-}" ] && candidates="$candidates
$JAVA_HOME/bin/java"
  if command -v java >/dev/null 2>&1; then
    candidates="$candidates
$(command -v java)"
  fi
  gu_home=${GRADLE_USER_HOME:-$HOME/.gradle}
  for props in "$ROOT/gradle.properties" "$gu_home/gradle.properties"; do
    [ -f "$props" ] || continue
    jhome=$(sed -n 's/^org\.gradle\.java\.home=\(.*\)/\1/p' "$props" | tail -n 1)
    [ -n "$jhome" ] && candidates="$candidates
$jhome/bin/java"
    jpaths=$(sed -n 's/^org\.gradle\.java\.installations\.paths=\(.*\)/\1/p' "$props" | tail -n 1)
    if [ -n "$jpaths" ]; then
      old_ifs=$IFS
      IFS=','
      for p in $jpaths; do
        candidates="$candidates
$p/bin/java"
      done
      IFS=$old_ifs
    fi
  done

  jdk_list=$(echo "$candidates" | while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    major=$(java_major_of "$cand" 2>/dev/null || true)
    [ -n "$major" ] || continue
    echo "$major $cand"
  done)

  found_lines=""
  matched=""
  old_ifs=$IFS
  IFS='
'
  for line in $jdk_list; do
    [ -n "$line" ] || continue
    major=${line%% *}
    cand=${line#* }
    found_lines="$found_lines    - JDK $major ($cand)
"
    if [ "$major" = "$expected_jdk" ] && [ -z "$matched" ]; then
      matched=$cand
    fi
  done
  IFS=$old_ifs

  if [ -z "$matched" ]; then
    log "[toolchain] FAIL: required JDK toolchain $expected_jdk not found"
    log "  expected: JDK $expected_jdk (gradle/libs.versions.toml)"
    log "  found:"
    printf '%s' "$found_lines"
    log "  hint: install JDK $expected_jdk or add it to org.gradle.java.installations.paths"
    log "  note: verify never downloads toolchains from the network"
    record "toolchain" "FAIL" "0"
    FAILED_PHASE=toolchain
    PHASE_RC=2
    return 1
  fi

  if [ ! -f gradle/wrapper/gradle-wrapper.jar ]; then
    log "[toolchain] FAIL: gradle/wrapper/gradle-wrapper.jar is missing"
    record "toolchain" "FAIL" "0"
    FAILED_PHASE=toolchain
    PHASE_RC=2
    return 1
  fi

  if [ "$OFFLINE" -eq 1 ]; then
    if ! ls -d "$gu_home"/wrapper/dists/gradle-"$expected_gradle"-* >/dev/null 2>&1; then
      log "[toolchain] FAIL: Gradle $expected_gradle is not in the wrapper cache and --offline was given"
      log "  expected: $gu_home/wrapper/dists/gradle-$expected_gradle-*"
      log "  hint: run 'sh tools/verify.sh --quick' once without --offline to warm the cache"
      record "toolchain" "FAIL" "0"
      FAILED_PHASE=toolchain
      PHASE_RC=2
      return 1
    fi
  fi

  end=$(now)
  log "[toolchain] JDK $expected_jdk: $matched"
  log "[toolchain] Gradle $expected_gradle (wrapper)"
  record "toolchain" "PASS" "$((end - start))"
  return 0
}

# ---------------------------------------------------------------------------
# Golden-file drift diagnosis: reruns the compiler-plugin tests in update mode
# against a snapshot, prints the minimal diff, and restores the goldens so the
# workspace is never modified.
# ---------------------------------------------------------------------------

diagnose_golden_drift() {
  golden_dir=moshi-ir/moshi-compiler-plugin/testData
  tmp=$(mktemp -d 2>/dev/null || mktemp -d -t moshix-verify)
  cp -R "$golden_dir" "$tmp/testData"
  # shellcheck disable=SC2086
  ./gradlew $GRADLE_FLAGS :moshi-ir:moshi-compiler-plugin:test \
    -Pmoshix.updateTestData=true >/dev/null 2>&1
  drift=$(diff -ru "$tmp/testData" "$golden_dir" 2>/dev/null || true)
  # Restore the snapshot exactly: overwrite changed files, delete created ones.
  ( cd "$tmp/testData" && find . -type f | sort ) > "$tmp/before.lst"
  ( cd "$golden_dir" && find . -type f | sort ) > "$tmp/after.lst"
  cp -R "$tmp/testData/." "$golden_dir/"
  grep -vxF -f "$tmp/before.lst" "$tmp/after.lst" | while IFS= read -r created; do
    [ -n "$created" ] && rm "$golden_dir/$created"
  done
  rm -r "$tmp" 2>/dev/null || true
  if [ -n "$drift" ]; then
    log "golden-file drift detected (diff: committed goldens vs regenerated):"
    echo "$drift"
    log "to accept the regenerated goldens run:"
    log "  ./gradlew :moshi-ir:moshi-compiler-plugin:test -Pmoshix.updateTestData=true"
  else
    log "no golden-file drift; see the test report for the root cause:"
    log "  moshi-ir/moshi-compiler-plugin/build/reports/tests/test/index.html"
  fi
}

# ---------------------------------------------------------------------------
# Archive hygiene: published jars must not contain build-cache state, absolute
# paths, or test fixtures.
# ---------------------------------------------------------------------------

check_archives() {
  bad=0
  jars=$(find . -path ./.git -prune -o -type f -name '*.jar' -path '*/build/libs/*' -print)
  for jar in $jars; do
    case "$jar" in
      *-sources.jar|*-javadoc.jar|*-testfixtures.jar) continue ;;
    esac
    entries=$(unzip -Z1 "$jar" 2>/dev/null) || {
      log "[archives] FAIL: unreadable jar: $jar"
      bad=1
      continue
    }
    hits=$(echo "$entries" | grep -E '(^|/)(testFixtures|test-gen|build-cache|\.gradle)(/|$)' || true)
    if [ -n "$hits" ]; then
      log "[archives] FAIL: $jar contains forbidden entries (test fixtures/build cache):"
      echo "$hits" | head -n 20
      bad=1
    fi
    if grep -qF "$ROOT" "$jar" 2>/dev/null; then
      log "[archives] FAIL: $jar embeds the absolute workspace path ($ROOT)"
      bad=1
    fi
  done
  if [ "$bad" -eq 0 ]; then
    log "[archives] all published jars are clean (no build cache, absolute paths, or test fixtures)"
  fi
  return $bad
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "mode=$MODE offline=$([ "$OFFLINE" -eq 1 ] && echo yes || echo no) root=$ROOT"

check_toolchain || fail

WORKSPACE_BEFORE=$(git status --porcelain 2>/dev/null || echo "no-git")

run_phase runtime \
  :moshix-runtime:check :moshi-sealed:runtime:check || fail

run_phase adapters \
  :moshi-adapters:check :moshi-immutable-adapters:check || fail

run_phase reflection \
  :moshi-metadata-reflect:check :moshi-sealed:metadata-reflect:check \
  :moshi-sealed:reflect:check :moshi-sealed:java-sealed-reflect:check || fail

run_phase sealed \
  :moshi-sealed:codegen:check || fail

# Compiler plugin: verify-only golden/generated-source checks plus the
# diagnostic suite, which runs real Kotlin compilations of testData sources.
if ! run_phase compiler-plugin \
  :moshi-ir:moshi-compiler-plugin:verifyGeneratedSources \
  :moshi-ir:moshi-compiler-plugin:test; then
  diagnose_golden_drift
  fail
fi

# Surface the golden compilation-test cases that ran.
suite_xml=$(ls moshi-ir/moshi-compiler-plugin/build/test-results/test/TEST-*.xml 2>/dev/null | head -n 1)
if [ -n "$suite_xml" ]; then
  suite_name=$(basename "$suite_xml" | sed -e 's/^TEST-//' -e 's/\.xml$//')
  suite_tests=$(sed -n 's/.*tests="\([0-9]*\)".*/\1/p' "$suite_xml" | head -n 1)
  log "   golden compilation cases: $suite_name ($suite_tests cases)"
fi

# Real end-to-end Kotlin compilation test: compiles Kotlin sources with the IR
# plugin applied and runs the generated adapters.
run_phase kotlin-compilation-tests \
  :moshi-ir:moshi-kotlin-tests:test || fail

# Publishing metadata: API dumps must be in sync and published jars must be clean.
if ! run_phase publishing-metadata apiCheck assemble; then
  fail
fi
start=$(now)
if ! check_archives; then
  record "archive-hygiene" "FAIL" "$(( $(now) - start ))"
  FAILED_PHASE=archive-hygiene
  PHASE_RC=1
  fail
fi
record "archive-hygiene" "PASS" "$(( $(now) - start ))"

if [ "$MODE" = "full" ]; then
  run_phase all-modules-build build || fail

  versions=${MOSHIX_VERIFY_KOTLIN_VERSIONS:-}
  if [ -z "$versions" ]; then
    versions=$(grep -v '^[[:space:]]*#' compiler-version-aliases.txt | grep -v '^[[:space:]]*$')
  fi
  if [ -z "$versions" ]; then
    log "FAIL: no Kotlin versions found in compiler-version-aliases.txt"
    FAILED_PHASE=version-matrix
    PHASE_RC=2
    fail
  fi
  for v in $versions; do
    for ksp in true false; do
      run_phase "matrix:kotlin-$v-ksp-$ksp" \
        :moshi-ir:moshi-compiler-plugin:test :moshi-ir:moshi-kotlin-tests:test \
        -PkotlinVersion="$v" -Pmoshix.useKsp="$ksp" || fail
    done
  done

  run_phase r8-tests :moshi-ir:moshi-kotlin-tests:testR8 || fail
fi

# Consecutive runs must not dirty the workspace.
start=$(now)
WORKSPACE_AFTER=$(git status --porcelain 2>/dev/null || echo "no-git")
if [ "$WORKSPACE_BEFORE" != "$WORKSPACE_AFTER" ]; then
  record "workspace-clean" "FAIL" "$(( $(now) - start ))"
  log "[workspace-clean] FAIL: verify modified tracked files:"
  git status --porcelain 2>/dev/null | head -n 30
  FAILED_PHASE=workspace-clean
  PHASE_RC=1
  fail
fi
record "workspace-clean" "PASS" "$(( $(now) - start ))"

print_summary
log "OK: all phases passed"
exit 0
