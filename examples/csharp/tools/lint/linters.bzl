"Define C# linter aspects"

load("@rules_lint//lint:csharp_analyzer.bzl", "lint_csharp_analyzer_aspect")
load("@rules_lint//lint:lint_test.bzl", "lint_test")

csharp_analyzer = lint_csharp_analyzer_aspect(
    configs = [Label("//:.globalconfig")],
)

csharp_analyzer_test = lint_test(aspect = csharp_analyzer)
