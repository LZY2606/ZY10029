// Copyright (C) 2026 Zac Sweers
// SPDX-License-Identifier: Apache-2.0
package dev.zacsweers.moshix.ir.compiler

import org.jetbrains.kotlin.generators.dsl.junit5.generateTestGroupSuiteWithJUnit5

fun main(args: Array<String>) {
  generateTestGroupSuiteWithJUnit5 {
    testGroup(
      testDataRoot = args.getOrElse(0) { "moshi-ir/moshi-compiler-plugin/testData" },
      testsRoot = args.getOrElse(1) { "moshi-ir/moshi-compiler-plugin/test-gen/java" },
    ) {
      testClass<AbstractMoshiDiagnosticTest> { model("diagnostic") }
    }
  }
}
