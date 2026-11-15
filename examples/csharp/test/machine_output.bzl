"C#-specific machine report rules for testing."

# buildifier: disable=bzl-visibility
load("@rules_lint//lint/private:machine_report_testing.bzl", "machine_report_rule")
load("//tools/lint:linters.bzl", "csharp_analyzer")

machine_csharp_analyzer_report = machine_report_rule(csharp_analyzer)
