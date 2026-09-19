#!/usr/bin/env bash

set -Eeuo pipefail

if [ -z "${BASH_VERSION:-}" ] || [ -n "${POSIXLY_CORRECT:-}" ]; then
  exec env -u POSIXLY_CORRECT bash "$0" "$@"
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$ROOT_DIR"

MODE=""
NETWORK_MODE="offline"
KOTLIN_FILTER=""
KSP_FILTER=""

usage() {
  cat <<'USAGE'
Usage: sh tools/verify.sh --quick [--online]
       sh tools/verify.sh --full [--online] [--kotlin VERSION] [--ksp true|false]

The default is offline. Run ./gradlew assemble once while online to warm the
quick build, or use --full --online once before an offline --full replay.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --quick) MODE="quick" ;;
    --full) MODE="full" ;;
    --online) NETWORK_MODE="online" ;;
    --offline) NETWORK_MODE="offline" ;;
    --kotlin)
      shift
      KOTLIN_FILTER=${1:?--kotlin requires a version}
      ;;
    --ksp)
      shift
      KSP_FILTER=${1:?--ksp requires true or false}
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [ -z "$MODE" ]; then
  usage >&2
  exit 2
fi

case "$KSP_FILTER" in
  ""|true|false) ;;
  *) echo "--ksp must be true or false" >&2; exit 2 ;;
esac

OUT_DIR="$ROOT_DIR/.verify"
LOG_DIR="$OUT_DIR/logs"
REPORT_DIR="$OUT_DIR/test-reports"
REPO_DIR="$OUT_DIR/maven-repository"
SUMMARY_TSV="$OUT_DIR/stages.tsv"
GOLDEN_ROOT="moshi-ir/moshi-compiler-plugin/golden/java"
GENERATED_ROOT="$OUT_DIR/generated-compiler-tests/java"

if [ -e "$OUT_DIR" ]; then
  find "$OUT_DIR" -depth -delete
fi
mkdir -p "$LOG_DIR" "$REPORT_DIR"

if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  INITIAL_GIT_STATUS=$(git status --porcelain --untracked-files=all)
else
  INITIAL_GIT_STATUS=""
fi

cleanup() {
  local generated_dir="$ROOT_DIR/moshi-ir/moshi-compiler-plugin/test-gen"
  if [ -e "$generated_dir" ]; then
    find "$generated_dir" -depth -delete
  fi
}

stage_count=0

finish() {
  local status=$?
  cleanup
  if [ -n "$INITIAL_GIT_STATUS" ]; then
    local current_status
    current_status=$(git status --porcelain --untracked-files=all)
    if [ "$current_status" != "$INITIAL_GIT_STATUS" ]; then
      echo >&2
      echo "Workspace changed during verification:" >&2
      git status --short >&2
      if [ "$status" -eq 0 ]; then
        status=20
      fi
    fi
  fi
  if [ "$status" -ne 0 ]; then
    if [ "$stage_count" -gt 0 ]; then
      print_summary >&2 || true
    fi
    echo "VERIFY FAILED with exit code $status" >&2
  fi
  exit "$status"
}
trap finish EXIT

print_summary() {
  if [ ! -f "$SUMMARY_TSV" ]; then
    return
  fi
  echo
  echo "Stage summary:"
  awk -F '\t' 'BEGIN { printf "  %-34s %-7s %s\n", "stage", "status", "seconds" } { printf "  %-34s %-7s %s\n", $1, $2, $3 }' "$SUMMARY_TSV"
}

record_stage() {
  local name=$1 status=$2 elapsed=$3
  stage_count=$((stage_count + 1))
  printf '%s\t%s\t%s\n' "$name" "$status" "$elapsed" >> "$SUMMARY_TSV"
}

gradle_common() {
  GRADLE_ARGS=(--no-daemon --stacktrace -Dorg.gradle.java.installations.auto-download=false)
  if [ "$NETWORK_MODE" = "offline" ]; then
    GRADLE_ARGS+=(--offline)
  fi
}

extract_catalog_version() {
  local key=$1
  sed -n "s/^${key}[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\"/\\1/p" gradle/libs.versions.toml | head -n 1
}

extract_wrapper_version() {
  awk -F'gradle-' '/^distributionUrl=/ { sub(/-bin[.]zip.*/, "", $2); print $2; exit }' gradle/wrapper/gradle-wrapper.properties
}

check_toolchain() {
  local required_jdk current_jdk required_gradle actual_gradle toolchains_log
  required_jdk=$(extract_catalog_version jdk)
  required_gradle=$(extract_wrapper_version)
  [ -n "$required_jdk" ] || { echo "Unable to read jdk version from gradle/libs.versions.toml" >&2; exit 3; }
  [ -n "$required_gradle" ] || { echo "Unable to read Gradle wrapper version" >&2; exit 4; }
  current_jdk=$(java -XshowSettings:properties -version 2>&1 | awk -F'= "' '/java[.]version = / { sub(/".*/, "", $2); print $2; exit }')

  gradle_common
  toolchains_log="$LOG_DIR/00-toolchains.log"
  echo "Checking JDK $required_jdk toolchain and Gradle $required_gradle before compilation..."
  if [ "$NETWORK_MODE" = "offline" ]; then
    local wrapper_dist_dir="$HOME/.gradle/wrapper/dists/gradle-$required_gradle-bin"
    if [ ! -d "$wrapper_dist_dir" ] || [ -z "$(find "$wrapper_dist_dir" -type f -path '*/bin/gradle' -print -quit)" ]; then
      echo "Gradle $required_gradle wrapper distribution is not cached for offline replay." >&2
      echo "Run ./gradlew assemble once with network access, then rerun verification." >&2
      exit 4
    fi
  fi
  ./gradlew "${GRADLE_ARGS[@]}" javaToolchains >"$toolchains_log" 2>&1
  actual_gradle=$(./gradlew "${GRADLE_ARGS[@]}" --version | awk '/^Gradle [0-9]/ { print $2; exit }')

  if ! grep -Eq "^[[:space:]]*\\|[[:space:]]*Language Version:[[:space:]]*${required_jdk}([^0-9]|$)" "$toolchains_log"; then
    {
      echo "Required JDK toolchain $required_jdk is not visible to Gradle."
      echo "Current JVM: ${current_jdk:-unknown}"
      echo "Detected toolchains:"
      awk '/^[[:space:]]*[+] / { vendor=$0 } /Language Version:/ { print "  - " vendor " / " $0 }' "$toolchains_log"
      echo
      echo "Install or point Gradle at JDK $required_jdk before running verification."
    } >&2
    exit 3
  fi

  if [ "$actual_gradle" != "$required_gradle" ]; then
    echo "Gradle version mismatch: expected $required_gradle, got ${actual_gradle:-unknown}" >&2
    exit 4
  fi

  echo "Toolchain OK: JDK $required_jdk, Gradle $required_gradle (${NETWORK_MODE})"
}

copy_test_reports() {
  local stage_name=$1
  local report_glob="*/build/test-results/*/*.xml"
  case "$stage_name" in
    r8-compilation-tests-*) report_glob="*/build/test-results/testR8/*.xml" ;;
    *) report_glob="*/build/test-results/test/*.xml" ;;
  esac
  echo "$stage_name" > "$REPORT_DIR/.last-stage"
  find . \
    -path "./$OUT_DIR" -prune -o \
    -type f -path "$report_glob" -print0 2>/dev/null |
    while IFS= read -r -d '' report; do
      local report_name
      report_name=${report#./}
      report_name=${report_name//\//__}
      cp "$report" "$REPORT_DIR/$report_name"
    done
}

run_gradle_stage() {
  local stage_name=$1
  shift
  local start_time end_time log_file status
  start_time=$SECONDS
  log_file="$LOG_DIR/${stage_name}.log"
  echo
  echo "==> $stage_name"
  gradle_common
  set +e
  ./gradlew "${GRADLE_ARGS[@]}" "$@" 2>&1 | tee "$log_file"
  status=${PIPESTATUS[0]}
  set -e
  end_time=$SECONDS
  copy_test_reports "$stage_name"
  record_stage "$stage_name" "$status" "$((end_time - start_time))"
  if [ "$status" -ne 0 ]; then
    echo "Stage $stage_name failed with Gradle exit code $status; log: $log_file" >&2
    exit "$status"
  fi
}

run_included_gradle_stage() {
  local project_dir=$1
  local stage_name=$2
  shift 2
  local start_time end_time log_file status
  start_time=$SECONDS
  log_file="$LOG_DIR/${stage_name}.log"
  echo
  echo "==> $stage_name"
  gradle_common
  set +e
  (
    cd "$project_dir"
    ./gradlew "${GRADLE_ARGS[@]}" "$@"
  ) 2>&1 | tee "$log_file"
  status=${PIPESTATUS[0]}
  set -e
  end_time=$SECONDS
  copy_test_reports "$stage_name"
  record_stage "$stage_name" "$status" "$((end_time - start_time))"
  if [ "$status" -ne 0 ]; then
    echo "Stage $stage_name failed with Gradle exit code $status; log: $log_file" >&2
    exit "$status"
  fi
}

check_golden_sources() {
  local stage_name="compiler-plugin-golden-sources"
  local start_time=$SECONDS status=0 generated relative golden
  echo
  echo "==> $stage_name (check only)"
  local generated_parent="$OUT_DIR/generated-compiler-tests"
  if [ -e "$generated_parent" ]; then
    find "$generated_parent" -depth -delete
  fi
  gradle_common
  set +e
  ./gradlew "${GRADLE_ARGS[@]}" \
    ":moshi-ir:moshi-compiler-plugin:generateTests" \
    "-Pmoshix.generatedTestsRoot=$GENERATED_ROOT" 2>&1 | tee "$LOG_DIR/$stage_name-generate.log"
  local generate_status=${PIPESTATUS[0]}
  set -e
  if [ "$generate_status" -ne 0 ]; then
    record_stage "$stage_name" "$generate_status" "$((SECONDS - start_time))"
    exit "$generate_status"
  fi

  while IFS= read -r -d '' generated; do
    relative=${generated#"$GENERATED_ROOT/"}
    golden="$GOLDEN_ROOT/$relative"
    if [ ! -f "$golden" ]; then
      echo "New generated source is missing from golden: $relative"
      diff -u --label "golden/$relative" --label "generated/$relative" /dev/null "$generated" | head -n 100 || true
      status=10
    elif ! diff -u --label "golden/$relative" --label "generated/$relative" "$golden" "$generated"; then
      status=10
    fi
  done < <(find "$GENERATED_ROOT" -type f -print0)

  while IFS= read -r -d '' golden; do
    relative=${golden#"$GOLDEN_ROOT/"}
    if [ ! -f "$GENERATED_ROOT/$relative" ]; then
      echo "Golden source is no longer generated: $relative"
      diff -u --label "golden/$relative" --label "generated/$relative" "$golden" /dev/null | head -n 100 || true
      status=10
    fi
  done < <(find "$GOLDEN_ROOT" -type f -print0)

  record_stage "$stage_name" "$status" "$((SECONDS - start_time))"
  if [ "$status" -ne 0 ]; then
    echo "Generated compiler test sources drifted. Review the minimal diff above; golden files were not modified." >&2
    exit "$status"
  fi
}

common_test_tasks=(
  :moshix-runtime:test
  :moshi-adapters:test
  :moshi-immutable-adapters:test
  :moshi-metadata-reflect:test
  :moshi-sealed:runtime:test
  :moshi-sealed:codegen:test
  :moshi-sealed:reflect:test
  :moshi-sealed:metadata-reflect:test
  :moshi-sealed:java-sealed-reflect:test
)

run_compiler_matrix_round() {
  local kotlin_version=$1 ksp_enabled=$2 label=$3
  local matrix_args=("-PkotlinVersion=$kotlin_version" "-Pmoshix.useKsp=$ksp_enabled")

  run_gradle_stage "runtime-adapters-reflection-tests-$label" cleanTest "${common_test_tasks[@]}"
  run_gradle_stage \
    "compiler-plugin-tests-$label" \
    ":moshi-ir:moshi-compiler-plugin:cleanTest" \
    ":moshi-ir:moshi-compiler-plugin:test" \
    "${matrix_args[@]}"
  run_gradle_stage \
    "kotlin-compilation-integration-tests-$label" \
    ":moshi-ir:moshi-kotlin-tests:cleanTest" \
    ":moshi-ir:moshi-kotlin-tests:test" \
    "${matrix_args[@]}"
  run_gradle_stage "r8-compilation-tests-$label" :moshi-ir:moshi-kotlin-tests:testR8 "${matrix_args[@]}"
}

matrix_entries() {
  grep -v '^[[:space:]]*#' compiler-version-aliases.txt |
    grep -v '^[[:space:]]*$' |
    while IFS= read -r kotlin_version; do
      for ksp_enabled in true false; do
        if [ -n "$KOTLIN_FILTER" ] && [ "$kotlin_version" != "$KOTLIN_FILTER" ]; then
          continue
        fi
        if [ -n "$KSP_FILTER" ] && [ "$ksp_enabled" != "$KSP_FILTER" ]; then
          continue
        fi
        printf '%s %s\n' "$kotlin_version" "$ksp_enabled"
      done
    done
}

audit_publish_archive() {
  local stage_name="publish-archive-audit"
  local start_time=$SECONDS status=0
  echo
  echo "==> $stage_name"

  if [ ! -d "$REPO_DIR" ]; then
    echo "Publish repository was not created: $REPO_DIR" >&2
    record_stage "$stage_name" 10 "$((SECONDS - start_time))"
    exit 10
  fi

  if find "$REPO_DIR" -type f | grep -Eiq 'test-fixtures?|build-cache|(^|/)cache[-_]'; then
    echo "Published repository contains test fixture or build-cache files:" >&2
    find "$REPO_DIR" -type f | grep -Ei 'test-fixtures?|build-cache|(^|/)cache[-_]' >&2
    status=11
  fi

  local text_violations
  text_violations=$(grep -RIlE "$ROOT_DIR|/(Users|home)/|test-fixtures?" "$REPO_DIR" 2>/dev/null || true)
  if [ -n "$text_violations" ]; then
    echo "Published repository contains absolute paths or test-fixture metadata:" >&2
    printf '%s\n' "$text_violations" >&2
    status=11
  fi

  while IFS= read -r -d '' archive; do
    local listing temp_dir
    listing=$(jar tf "$archive")
    if printf '%s\n' "$listing" | grep -Eiq '(^|/)(build|test-fixtures?)(/|$)|build-cache'; then
      echo "Archive contains build, cache, or test-fixture entries: $archive" >&2
      printf '%s\n' "$listing" | grep -Ei '(^|/)(build|test-fixtures?)(/|$)|build-cache' >&2
      status=11
    fi
    temp_dir=$(mktemp -d)
    if ! (cd "$temp_dir" && jar xf "$archive" && grep -RIlE "$ROOT_DIR|/(Users|home)/" .); then
      :
    else
      echo "Archive contains absolute host paths: $archive" >&2
      status=11
    fi
    find "$temp_dir" -depth -delete
  done < <(find "$REPO_DIR" -type f \( -name '*.jar' -o -name '*.zip' \) -print0)

  record_stage "$stage_name" "$status" "$((SECONDS - start_time))"
  if [ "$status" -ne 0 ]; then
    exit "$status"
  fi
}

publish_metadata() {
  if [ -e "$REPO_DIR" ]; then
    find "$REPO_DIR" -depth -delete
  fi
  mkdir -p "$REPO_DIR"
  run_gradle_stage \
    "publish-metadata" \
    "-Dverify.repository=file:$REPO_DIR" \
    publishAllPublicationsToVerifyLocalRepository
  run_included_gradle_stage \
    "moshi-ir/moshi-gradle-plugin" \
    "publish-gradle-plugin-metadata" \
    "-Dverify.repository=file:$REPO_DIR" \
    publishAllPublicationsToVerifyLocalRepository
  audit_publish_archive
}

run_quick() {
  check_golden_sources
  run_gradle_stage "runtime-tests" cleanTest :moshix-runtime:test
  run_gradle_stage "adapters-tests" cleanTest :moshi-adapters:test :moshi-immutable-adapters:test
  run_gradle_stage "reflection-tests" cleanTest :moshi-metadata-reflect:test
  run_gradle_stage \
    "sealed-tests" \
    cleanTest \
    :moshi-sealed:runtime:test \
    :moshi-sealed:codegen:test \
    :moshi-sealed:reflect:test \
    :moshi-sealed:metadata-reflect:test \
    :moshi-sealed:java-sealed-reflect:test
  run_gradle_stage "compiler-plugin-tests" :moshi-ir:moshi-compiler-plugin:cleanTest :moshi-ir:moshi-compiler-plugin:test
  run_gradle_stage "kotlin-compilation-integration-tests" :moshi-ir:moshi-kotlin-tests:cleanTest :moshi-ir:moshi-kotlin-tests:test
  run_included_gradle_stage "moshi-ir/moshi-gradle-plugin" "gradle-plugin-tests" cleanTest test
  run_gradle_stage "binary-api-metadata" apiCheck
  publish_metadata
}

run_full() {
  local combinations
  combinations=$(matrix_entries)
  if [ -z "$combinations" ]; then
    echo "No matrix entries match --kotlin '$KOTLIN_FILTER' --ksp '$KSP_FILTER'." >&2
    exit 2
  fi

  check_golden_sources
  run_included_gradle_stage "moshi-ir/moshi-gradle-plugin" "gradle-plugin-tests" cleanTest test

  while IFS=' ' read -r kotlin_version ksp_enabled; do
    local label
    label="kotlin-${kotlin_version}-ksp-${ksp_enabled}"
    echo
    echo "Matrix: Kotlin $kotlin_version / KSP $ksp_enabled"
    run_compiler_matrix_round "$kotlin_version" "$ksp_enabled" "$label"
  done <<< "$combinations"

  run_gradle_stage "binary-api-metadata" apiCheck
  if [ -z "$KOTLIN_FILTER" ] && [ -z "$KSP_FILTER" ]; then
    publish_metadata
  else
    echo "Skipping publish metadata for filtered matrix shard: Kotlin '$KOTLIN_FILTER', KSP '$KSP_FILTER'"
  fi
}

print_test_summary() {
  local totals
  if [ ! -d "$REPORT_DIR" ] || [ -z "$(find "$REPORT_DIR" -type f -name '*.xml' -print -quit 2>/dev/null)" ]; then
    return
  fi
  totals=$(
    find "$REPORT_DIR" -type f -name '*.xml' -print0 |
      xargs -0 grep -h '<testsuite ' 2>/dev/null |
      awk '
        {
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^tests=/) { split($i, a, "\""); tests += a[2] }
            if ($i ~ /^failures=/) { split($i, a, "\""); failures += a[2] }
            if ($i ~ /^errors=/) { split($i, a, "\""); errors += a[2] }
            if ($i ~ /^skipped=/) { split($i, a, "\""); skipped += a[2] }
          }
        }
        END { printf "%d tests, %d failures, %d errors, %d skipped", tests, failures, errors, skipped }'
  )
  echo "Test summary: $totals"
  echo "JUnit XML: $REPORT_DIR"
}

check_toolchain
if [ "$MODE" = "quick" ]; then
  run_quick
else
  run_full
fi

echo
echo "VERIFY SUCCEEDED ($MODE, $NETWORK_MODE)"
print_summary
print_test_summary
