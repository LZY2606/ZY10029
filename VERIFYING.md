# Verifying MoshiX

`tools/verify.sh` is the single verify entry point shared by local development
and CI. It checks the toolchain, runs module tests in dependency order, verifies
the compiler plugin's golden/generated sources, and validates publishing
metadata — without ever modifying the workspace or silently downloading missing
inputs.

```console
# Fast check (what to run before pushing)
sh tools/verify.sh --quick

# Full check (what CI runs): everything in --quick plus the version matrix
sh tools/verify.sh --full

# Replay without network access (requires a warmed cache, see below)
sh tools/verify.sh --quick --offline
```

Run it from the repository root. The script exits with the original exit code of
the first failing phase and prints a phase summary on both success and failure.

## Phases

Phases run in dependency-topological order; each is one Gradle invocation:

| Phase | What it does |
| --- | --- |
| `toolchain` | Verifies the JDK toolchain (`jdk` in `gradle/libs.versions.toml`) and the Gradle wrapper version (`gradle/wrapper/gradle-wrapper.properties`) **before any compilation**. Missing toolchains fail with an expected-vs-found version diff. |
| `runtime` | `:moshix-runtime`, `:moshi-sealed:runtime` tests. |
| `adapters` | `:moshi-adapters`, `:moshi-immutable-adapters` tests. |
| `reflection` | `:moshi-metadata-reflect` and the sealed reflection artifacts. |
| `sealed` | `:moshi-sealed:codegen` tests. |
| `compiler-plugin` | `verifyGeneratedSources` (see below) plus the diagnostic suite, which runs real Kotlin compilations of `testData` sources against golden files. |
| `kotlin-compilation-tests` | `:moshi-ir:moshi-kotlin-tests` — end-to-end Kotlin compilation with the IR plugin applied. |
| `publishing-metadata` | `apiCheck` (API dump drift) and `assemble`. |
| `archive-hygiene` | Published jars must not contain build-cache state, absolute paths, or test fixtures. |
| `workspace-clean` | Fails if any verify step modified tracked files. |

`--full` additionally runs `all-modules-build` (`./gradlew build`), the
Kotlin/KSP version matrix declared in `compiler-version-aliases.txt`
(`matrix:kotlin-<version>-ksp-<true|false>` phases), and `r8-tests`
(`:moshi-ir:moshi-kotlin-tests:testR8`). Set `MOSHIX_VERIFY_KOTLIN_VERSIONS` to a
space-separated list to override the matrix versions.

## Golden and generated sources (verify-only)

The compiler plugin has two kinds of generated content, both verified without
overwriting:

- **Generated test sources** (`moshi-ir/moshi-compiler-plugin/test-gen`): the
  `verifyGeneratedSources` Gradle task regenerates them from `testData` into a
  throwaway build directory and fails with a unified diff if they drift.
- **Golden files** (`testData/**/*.diag.txt`): the diagnostic tests always run
  in verify-only mode (`kotlin.test.update.test.data=false` by default). On
  drift the phase fails and `verify.sh` prints a minimal diff between the
  committed goldens and a regenerated copy, then restores the goldens.

To accept regenerated goldens after an intentional compiler change:

```console
./gradlew :moshi-ir:moshi-compiler-plugin:test -Pmoshix.updateTestData=true
```

To regenerate the test sources after changing the generator:

```console
./gradlew :moshi-ir:moshi-compiler-plugin:generateTests
```

## Caching and offline replay

- Warm the cache once with `./gradlew assemble` and one `sh tools/verify.sh
  --quick` run; afterwards `--offline` replays fully offline.
- `--offline` passes `--offline` to every Gradle invocation and additionally
  requires the Gradle distribution itself to already be in the wrapper cache.
- The script never downloads toolchains: it passes
  `-Dorg.gradle.java.installations.auto-download=false` and fails up front if
  the declared JDK is not installed locally.
- Consecutive runs are idempotent: generated output goes to git-ignored
  directories only, and the `workspace-clean` phase enforces this.

## Failure diagnosis

- The phase summary marks the failing phase; the script exits with that phase's
  original exit code (`2` for toolchain/usage errors).
- Test reports: `*/build/reports/tests/<task>/index.html`; JUnit XML:
  `*/build/test-results/<task>/*.xml` (uploaded as the `test-summaries`
  artifact in CI).
- Golden drift: the failure output includes a minimal diff of the committed
  goldens versus the regenerated output, plus the command to accept it.
- Archive hygiene failures list the offending jar entries (test fixtures,
  build-cache state) or the embedded absolute path.

## CI

The `build` job in `.github/workflows/ci.yml` runs `sh tools/verify.sh --full`
and uploads per-module test summaries. The version matrix lives in
`compiler-version-aliases.txt` and is expanded by `verify.sh` itself, so local
and CI runs are identical.
