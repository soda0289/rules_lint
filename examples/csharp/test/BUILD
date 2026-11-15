# buildifier: disable=bzl-visibility
load("@rules_lint//lint/private:machine_report_testing.bzl", "report_test")
load("//test:machine_output.bzl", "machine_csharp_analyzer_report")
load("//tools/lint:linters.bzl", "csharp_analyzer_test")

package(default_visibility = ["//visibility:public"])

csharp_analyzer_test(
    name = "lint_clean_lib",
    srcs = ["//src:clean_lib"],
)

csharp_analyzer_test(
    name = "lint_hello_csharp",
    srcs = ["//src:hello_csharp"],
    expected_exit_code = 1,
)

machine_csharp_analyzer_report(
    name = "machine_csharp_analyzer_report",
    src = "//src:hello_csharp",
)

report_test(
    name = "csharp_analyzer_machine_output_test",
    expected_tool = "Microsoft (R) Visual C# Compiler",
    expected_uri = "src/hello.cs",
    report = "machine_csharp_analyzer_report",
)
