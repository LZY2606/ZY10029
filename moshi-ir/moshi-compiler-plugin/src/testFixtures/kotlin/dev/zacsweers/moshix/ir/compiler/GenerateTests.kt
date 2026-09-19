// Copyright (C) 2026 Zac Sweers
// SPDX-License-Identifier: Apache-2.0
package dev.zacsweers.moshix.ir.compiler

import org.jetbrains.kotlin.generators.dsl.junit5.generateTestGroupSuiteWithJUnit5

fun main() {
  val testDataRoot =
    System.getProperty("moshix.testDataRoot")
      ?: "moshi-ir/moshi-compiler-plugin/testData"
  val testsRoot =
    System.getProperty("moshix.generatedTestsRoot")
      ?: "moshi-ir/moshi-compiler-plugin/test-gen/java"

  generateTestGroupSuiteWithJUnit5 {
    testGroup(
      testDataRoot = testDataRoot,
      testsRoot = testsRoot,
    ) {
      testClass<AbstractMoshiDiagnosticTest> { model("diagnostic") }
    }
  }
}
