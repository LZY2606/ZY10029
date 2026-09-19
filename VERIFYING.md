# Verifying MoshiX

All local and CI verification goes through `tools/verify.sh`. The script must be
run from the repository root; invoking it as `sh tools/verify.sh ...` is
supported.

## Modes

- `sh tools/verify.sh --quick`: validates the default Kotlin/Moshi toolchain,
  compiler-test golden sources, runtime, adapters, reflection, sealed modules,
  a real Kotlin compiler-plugin test, the Kotlin integration compilation tests,
  the included Gradle plugin, binary API metadata, and local publish metadata.
- `sh tools/verify.sh --full`: runs the quick-independent compiler and runtime
  checks for every Kotlin version in `compiler-version-aliases.txt`, with both
  `moshix.useKsp=true` and `moshix.useKsp=false`, then runs R8 verification and
  publish metadata.
- `sh tools/verify.sh --full --kotlin 2.4.10 --ksp true`: verifies one CI
  matrix shard. Filtered full runs skip publishing metadata.

The default network mode is offline. Add `--online` only for an intentional
dependency warm-up or CI run; verification does not silently use the network to
fill missing inputs. Gradle toolchain auto-download is disabled.

## Toolchain gate

Before any project compilation, the script checks:

- JDK `jdk` from `gradle/libs.versions.toml` is visible to
  `./gradlew javaToolchains`.
- The active Gradle wrapper version matches
  `gradle/wrapper/gradle-wrapper.properties`.

The failure output lists the required version and the toolchains Gradle can see.
Install the required JDK or make it visible with
`org.gradle.java.installations.paths`; do not rely on automatic provisioning.

## Caching and offline replay

Quick warm-up:

```sh
./gradlew assemble
sh tools/verify.sh --quick
```

Full offline replay requires an initial online full warm-up:

```sh
sh tools/verify.sh --full --online
sh tools/verify.sh --full
```

CI uses `gradle/actions/setup-gradle`, `--online`, and the same script. Matrix
jobs pass `--kotlin` and `--ksp`; the quick job validates publish metadata.

Generated compiler tests are written under `.verify` and compared with the
checked-in files in `moshi-ir/moshi-compiler-plugin/golden/java`. The check is
read-only: it prints a minimal unified diff and fails on missing, removed, or
changed generated sources without modifying golden files. Update golden files
only after deliberately regenerating and reviewing the expected change.

## Outputs

- `.verify/logs/`: one log per verification stage plus the toolchain report.
- `.verify/test-reports/`: JUnit XML copied from every module and matrix shard.
- `.verify/maven-repository/`: isolated local Maven publish output.
- `.verify/stages.tsv`: stage name, raw exit status, and elapsed seconds.

The local publish archive is rejected if it contains build-cache artifacts,
test fixtures, or absolute host paths. Verification also restores any ignored
`test-gen` directory and fails if the Git workspace changes during a run.

## Failure diagnosis

- Toolchain failure: install the reported JDK before rerunning.
- Offline dependency failure: run the corresponding `--online` verification once
  to warm Gradle's cache, then replay without `--online`.
- Golden drift: inspect the compact diff under
  `compiler-plugin-golden-sources`; rerun after intentionally updating the
  golden source.
- Test failure: open the stage log and the module's JUnit XML copied under
  `.verify/test-reports/`.
- Publishing failure: inspect `publish-metadata`,
  `publish-gradle-plugin-metadata`, and `publish-archive-audit` logs.

The script preserves the failing Gradle or audit command's non-zero exit code
and prints the completed stage summary before exiting.
