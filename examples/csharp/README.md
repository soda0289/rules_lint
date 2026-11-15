# C# Formatting and Linting Example

This example demonstrates how to set up formatting and Roslyn analyzer linting for C# code using `rules_lint`.

## Supported Tools

### Formatters

- **CSharpier** - Opinionated C# code formatter

### Linters

- **.NET SDK Roslyn Analyzers** (`CAxxxx` code quality rules and `IDExxxx` code style/formatting rules) and third-party Roslyn analyzers (such as Roslynator or StyleCop) via `lint_csharp_analyzer_aspect`

## Setup

1. Configure `MODULE.bazel` with the required dependencies and .NET toolchain
2. Configure the Paket dependencies in `paket.dependencies` and `3rdparty/nuget/`
3. Configure the formatter and linter:

- See `tools/format/BUILD` for how to set up the formatter
- See `tools/lint/linters.bzl` and `.globalconfig` for how to set up the C# analyzer aspect
- See `3rdparty/nuget/` for Paket dependency setup

4. Perform formatting using `aspect format` and linting using `aspect lint` or `bazel test //test/...`

## Example Code

The `src/` directory contains example C# files:

- `hello.cs` - Simple C# file with formatting/analyzer violations
- `clean_lib.cs` - Clean C# library that passes analyzer checks

## Configuration Files

- `.globalconfig` - Global analyzer configuration for C# code style and quality rules
- `paket.dependencies` - Paket dependency file for CSharpier
- `3rdparty/nuget/` - Generated paket files
