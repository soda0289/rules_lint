"""API for declaring a C# Roslyn analyzer lint aspect that visits csharp_{binary|library|test} rules.

Runs the .NET SDK's built-in Roslyn analyzers (`CAxxxx` code quality rules,
`IDExxxx` code style and formatting rules, and ASP.NET Core Web SDK rules) as
well as any additional third-party Roslyn analyzer packages (such as
[Roslynator](https://github.com/JosefPihrt/Roslynator) or
[StyleCop.Analyzers](https://github.com/DotNetAnalyzers/StyleCopAnalyzers))
and `.editorconfig` / `.globalconfig` configuration files.

Typical usage:

First, configure `rules_dotnet` in `MODULE.bazel` (with `rules_dotnet` containing
`DotnetCSharpAnalyzerInfo` support).

Optionally create an `.editorconfig` or `.globalconfig` file to configure rule
severities (for example `dotnet_diagnostic.CA1822.severity = warning` or
`dotnet_diagnostic.IDE0055.severity = warning`).

Then declare the linter aspect in `tools/lint/linters.bzl`:

```starlark
load("@rules_lint//lint:csharp_analyzer.bzl", "lint_csharp_analyzer_aspect")
load("@rules_lint//lint:lint_test.bzl", "lint_test")

csharp_analyzer = lint_csharp_analyzer_aspect(
    configs = [Label("//:.globalconfig")],
    # Optional: analysis_mode preset ("default", "none", "minimum", "recommended", "all")
    analysis_mode = "recommended",
    # Optional: third-party Roslyn analyzer targets from paket/NuGet
    analyzers = [
        # Label("@paket.main//roslynator.analyzers"),
    ],
)

csharp_analyzer_test = lint_test(aspect = csharp_analyzer)
```

Now your C# targets can be linted with `aspect lint` or tested with `csharp_analyzer_test`.
"""

load("@jq.bzl//jq:jq.bzl", "jq_lib")
load(
    "@rules_dotnet//dotnet:defs.bzl",
    "DotnetAssemblyCompileInfo",
    "DotnetCSharpAnalyzerInfo",
    "sdk_analyzer_compile_inputs",
)
load("//lint/private:lint_aspect.bzl", "LintOptionsInfo", "OUTFILE_FORMAT", "filter_srcs", "noop_lint_action", "output_files", "should_visit")

_MNEMONIC = "AspectRulesLintCSharpAnalyzer"
_DOTNET_TOOLCHAIN_TYPE = "@rules_dotnet//dotnet/toolchain:toolchain_type"

DEFAULT_RULE_KINDS = [
    "csharp_binary",
    "csharp_library",
    "csharp_nunit_test",
    "csharp_test",
]

def _collect_extra_analyzers(targets):
    files = []
    for entry in targets:
        if type(entry) == "File":
            files.append(entry)
        elif DotnetAssemblyCompileInfo in entry:
            compile_info = entry[DotnetAssemblyCompileInfo]
            files.extend(compile_info.analyzers)
            files.extend(compile_info.analyzers_csharp)
            files.extend(compile_info.transitive_analyzers.to_list())
            files.extend(compile_info.transitive_analyzers_csharp.to_list())
        elif DefaultInfo in entry:
            files.extend(entry[DefaultInfo].files.to_list())
    return files

def _collect_files(entries):
    files = []
    for entry in entries:
        if type(entry) == "File":
            files.append(entry)
        elif DefaultInfo in entry:
            files.extend(entry[DefaultInfo].files.to_list())
    return files

def _format_ref_arg(assembly):
    if assembly.path.endswith("System.EnterpriseServices.Thunk.dll") or assembly.path.endswith("System.EnterpriseServices.Wrapper.dll"):
        return None
    return "-r:\"" + assembly.path + "\""

def _dedupe_analyzers(direct_lists, transitive_depsets):
    seen = {}
    out = []
    for lst in direct_lists:
        for f in lst:
            if f.basename not in seen:
                seen[f.basename] = True
                out.append(f)
    for d in transitive_depsets:
        for f in d.to_list():
            if f.basename not in seen:
                seen[f.basename] = True
                out.append(f)
    return depset(out)

def _run_csc_sarif_action(
        ctx,
        target,
        raw_sarif,
        enable_net_analyzers,
        enforce_code_style,
        analysis_mode,
        analyzers,
        configs,
        additionalfiles):
    if DotnetCSharpAnalyzerInfo not in target:
        return False

    info = target[DotnetCSharpAnalyzerInfo]
    toolchain = ctx.toolchains[_DOTNET_TOOLCHAIN_TYPE]
    sdk_inputs = sdk_analyzer_compile_inputs(
        toolchain = toolchain,
        target_framework = info.target_framework,
        project_sdk = info.project_sdk,
        enable_net_analyzers = enable_net_analyzers,
        enforce_code_style_in_build = enforce_code_style,
        analysis_mode = analysis_mode,
    )

    extra_analyzer_files = _collect_extra_analyzers(analyzers)
    extra_config_files = _collect_files(configs)
    extra_additional_files = _collect_files(additionalfiles)

    scratch_config = ctx.actions.declare_file(
        OUTFILE_FORMAT.format(label = target.label.name, mnemonic = _MNEMONIC, suffix = "analyze.globalconfig"),
    )
    scratch_dir_path = raw_sarif.path + ".analyze"
    ctx.actions.write(
        output = scratch_config,
        content = "\n".join([
            "is_global = true",
            "build_property.IntermediateOutputPath = {}/".format(scratch_dir_path),
            "build_property.OutDir = {}/".format(scratch_dir_path),
            "build_property.RootNamespace = {}".format(info.assembly_name),
            "build_property.DefaultNamespace = {}".format(info.assembly_name),
            "build_property.TargetFramework = {}".format(info.target_framework),
            "",
        ]),
    )

    csc_args = ctx.actions.args()
    csc_args.set_param_file_format("multiline")
    csc_args.add("-unsafe+" if info.allow_unsafe_blocks else "-unsafe-")
    csc_args.add("-checked-")
    csc_args.add("-nostdlib+")
    csc_args.add("-utf8output")
    csc_args.add("-deterministic+")
    csc_args.add("-filealign:512")
    csc_args.add("-nologo")
    csc_args.add("-debug-")
    csc_args.add("-optimize+")
    csc_args.add("-define:TRACE")
    csc_args.add("-define:RELEASE")
    csc_args.add("-warnaserror-")
    csc_args.add("-warn:{}".format(info.warning_level))
    if len(info.nowarn) > 0:
        csc_args.add("-nowarn:{}".format(",".join(info.nowarn)))

    if info.nullable in ["enable", "warnings", "annotations"]:
        csc_args.add("-nullable:" + info.nullable)
    else:
        csc_args.add("-nullable:disable")

    if info.subsystem_version != None:
        csc_args.add("-subsystemversion:" + info.subsystem_version)

    csc_args.add("-target:" + info.target)
    csc_args.add("-langversion:" + info.langversion)
    csc_args.add(raw_sarif, format = "-out:\"%%s.analyze/%s\"" % info.out_dll_name)
    csc_args.add(raw_sarif, format = "-errorlog:\"%s\",version=2.1")

    all_refs = depset(transitive = [info.refs, info.framework_files])
    csc_args.add_all(all_refs, map_each = _format_ref_arg)

    all_analyzers = _dedupe_analyzers(
        [sdk_inputs.analyzers, extra_analyzer_files],
        [info.analyzers, info.analyzers_csharp],
    )
    csc_args.add_all(all_analyzers, format_each = "-analyzer:\"%s\"")

    all_additionalfiles = depset(
        extra_additional_files,
        transitive = [info.additionalfiles],
    )
    csc_args.add_all(all_additionalfiles, format_each = "-additionalfile:\"%s\"")

    all_configs = depset(
        sdk_inputs.analyzer_configs +
        info.analyzer_configs.to_list() +
        extra_config_files +
        [scratch_config],
    )
    csc_args.add_all(all_configs, format_each = "-analyzerconfig:\"%s\"")

    csc_args.add_all(info.srcs, format_each = "\"%s\"")
    csc_args.add_all(info.defines, format_each = "-d:%s")

    if info.keyfile != None:
        csc_args.add(info.keyfile, format = "-keyfile:\"%s\"")

    for option in info.compiler_options:
        csc_args.add(option)

    if info.interceptors_namespaces:
        csc_args.add("-features:InterceptorsNamespaces=" + ";".join(info.interceptors_namespaces))

    rsp_file = ctx.actions.declare_file(
        OUTFILE_FORMAT.format(label = target.label.name, mnemonic = _MNEMONIC, suffix = "csc.params"),
    )
    ctx.actions.write(
        output = rsp_file,
        content = csc_args,
    )

    dotnet_exe = toolchain.compiler_host.files_to_run.executable
    csc_dll = toolchain.csharp_compiler.files_to_run.executable

    launcher_args = ctx.actions.args()
    launcher_args.add(dotnet_exe)
    launcher_args.add(csc_dll)
    launcher_args.add(raw_sarif)
    launcher_args.add(rsp_file)

    direct_inputs = [scratch_config, rsp_file] + ([info.keyfile] if info.keyfile != None else [])

    ctx.actions.run_shell(
        mnemonic = _MNEMONIC,
        progress_message = "Linting %{label} with C# Roslyn analyzers",
        inputs = depset(
            direct = direct_inputs,
            transitive = [
                info.srcs,
                all_refs,
                all_analyzers,
                all_additionalfiles,
                all_configs,
                info.compile_data,
            ],
        ),
        tools = depset(
            direct = [dotnet_exe, csc_dll],
            transitive = [
                toolchain.compiler_host.default_runfiles.files,
                toolchain.csharp_compiler.default_runfiles.files,
            ],
        ),
        outputs = [raw_sarif],
        arguments = [launcher_args],
        command = """
dotnet="$1"
csc="$2"
sarif="$3"
rsp="$4"
scratch="${sarif}.analyze"
mkdir -p "${scratch}"
export DOTNET_CLI_HOME="$(dirname "${dotnet}")"
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"
set +e
output=$("${dotnet}" exec "${csc}" -noconfig "@${rsp}" "-pathmap:${PWD}=." 2>&1)
status=$?
set -e
rm -rf "${scratch}"
if [[ ! -f "${sarif}" ]]; then
    echo "${output}" >&2
    exit "${status}"
fi
""",
    )
    return True

# Normalizes raw csc SARIF v2.1 output:
# 1. Filters `.runs[].results` to unsuppressed diagnostics with level "warning"
#    or "error" (excluding informational compiler/analyzer notes such as CA1016
#    and diagnostics suppressed via `#pragma warning disable` / `[SuppressMessage]`,
#    which Roslyn's SARIF v2.1 logger still emits with a non-empty `suppressions`
#    array).
# 2. Converts any absolute `file://.../execroot/<workspace>/` URIs emitted by
#    `csc` on Windows or sandboxed builds into workspace-relative paths.
_NORMALIZE_SARIF_JQ_FILTER = """
walk(
  if type == "object" and has("artifactLocation") and (.artifactLocation | type == "object") and (.artifactLocation.uri | type == "string") then
    .artifactLocation.uri |= (
      sub("^file://.*/execroot/[^/]+/"; "")
      | sub("^file:///"; "")
    )
  else
    .
  end
)
| .runs |= map(
    .results = (
      (.results // [])
      | map(select((.level == "warning" or .level == "error") and (((.suppressions // []) | length) == 0)))
    )
  )
"""

# Formats normalized SARIF results into standard MSBuild/csc human-readable lines:
# `<uri>(<line>,<col>): <level> <ruleId>: <message>`
_HUMAN_FROM_SARIF_JQ_FILTER = """
.runs[]?.results[]?
| (.locations[0]?.physicalLocation // {}) as $loc
| ($loc.artifactLocation.uri // "") as $uri
| ($loc.region.startLine // 0) as $line
| ($loc.region.startColumn // 0) as $col
| (if $uri != "" and $line > 0 then $uri + "(" + ($line | tostring) + "," + ($col | tostring) + "): " elif $uri != "" then $uri + ": " else "" end)
  + .level + " " + .ruleId + ": " + .message.text
"""

def _emit_human_and_exit_code_action(ctx, sarif_report, human_report, outputs, fail_on_violation):
    outs = [outputs.human.out]
    args = ctx.actions.args()
    args.add(human_report)
    args.add(outputs.human.out)

    command = """
if [[ -s "$1" ]]; then
    cp "$1" "$2"
    exit_code=1
else
    touch "$2"
    exit_code=0
fi
"""
    if fail_on_violation:
        command += """
if [[ "${exit_code}" != 0 ]]; then
    cat "$2" >&2
    exit "${exit_code}"
fi
"""
    else:
        command += """
echo "${exit_code}" > "$3"
echo "${exit_code}" > "$4"
"""
        args.add(outputs.human.exit_code)
        args.add(outputs.machine.exit_code)
        outs.append(outputs.human.exit_code)
        outs.append(outputs.machine.exit_code)

    ctx.actions.run_shell(
        inputs = [human_report, sarif_report],
        outputs = outs,
        arguments = [args],
        command = command,
        mnemonic = _MNEMONIC + "Report",
        progress_message = "Formatting C# analyzer lint results for %{label}",
    )

def csharp_analyzer_action(
        ctx,
        target,
        outputs,
        enable_net_analyzers = True,
        enforce_code_style = True,
        analysis_mode = "default",
        analyzers = [],
        configs = [],
        additionalfiles = [],
        fail_on_violation = False):
    """Runs Roslyn analyzers on a C# target and writes human and SARIF outputs.

    Args:
        ctx: Bazel Aspect evaluation context
        target: the C# target to lint
        outputs: struct returned from `output_files`
        enable_net_analyzers: whether to include the .NET SDK's `CAxxxx` analyzers
        enforce_code_style: whether to include the .NET SDK's `IDExxxx` code style analyzers
        analysis_mode: SDK analyzer preset (`default`, `none`, `minimum`, `recommended`, `all`)
        analyzers: list of additional analyzer targets or files
        configs: list of `.editorconfig` / `.globalconfig` files
        additionalfiles: list of `/additionalfile:` inputs for analyzers
        fail_on_violation: whether to fail the build action when violations are present

    Returns:
        True if a lint action was registered on `target`, False otherwise.
    """
    raw_sarif = ctx.actions.declare_file(
        OUTFILE_FORMAT.format(label = target.label.name, mnemonic = _MNEMONIC, suffix = "raw.sarif"),
    )

    ok = _run_csc_sarif_action(
        ctx,
        target,
        raw_sarif,
        enable_net_analyzers = enable_net_analyzers,
        enforce_code_style = enforce_code_style,
        analysis_mode = analysis_mode,
        analyzers = analyzers,
        configs = configs,
        additionalfiles = additionalfiles,
    )
    if not ok:
        return False

    jq_lib.jq_action(
        ctx,
        sources = [raw_sarif],
        filter = _NORMALIZE_SARIF_JQ_FILTER,
        out = outputs.machine.out,
        args = [],
    )

    raw_human = ctx.actions.declare_file(
        OUTFILE_FORMAT.format(label = target.label.name, mnemonic = _MNEMONIC, suffix = "raw.human"),
    )
    jq_lib.jq_action(
        ctx,
        sources = [outputs.machine.out],
        filter = _HUMAN_FROM_SARIF_JQ_FILTER,
        out = raw_human,
        args = ["--raw-output"],
    )

    _emit_human_and_exit_code_action(
        ctx,
        outputs.machine.out,
        raw_human,
        outputs,
        fail_on_violation,
    )
    return True

# buildifier: disable=function-docstring
def _csharp_analyzer_aspect_impl(target, ctx):
    if not should_visit(ctx.rule, ctx.attr._rule_kinds):
        return []

    files_to_lint = filter_srcs(ctx.rule)
    outputs, info = output_files(_MNEMONIC, target, ctx)

    if len(files_to_lint) == 0:
        noop_lint_action(ctx, outputs)
        return [info]

    ok = csharp_analyzer_action(
        ctx,
        target,
        outputs,
        enable_net_analyzers = ctx.attr._enable_net_analyzers,
        enforce_code_style = ctx.attr._enforce_code_style,
        analysis_mode = ctx.attr._analysis_mode,
        analyzers = ctx.attr._analyzers,
        configs = ctx.files._configs,
        additionalfiles = ctx.files._additionalfiles,
        fail_on_violation = ctx.attr._options[LintOptionsInfo].fail_on_violation,
    )
    if not ok:
        noop_lint_action(ctx, outputs)

    return [info]

def lint_csharp_analyzer_aspect(
        configs = [],
        analyzers = [],
        additionalfiles = [],
        enable_net_analyzers = True,
        enforce_code_style = True,
        analysis_mode = "default",
        rule_kinds = DEFAULT_RULE_KINDS):
    """A factory function to create a C# Roslyn analyzer linter aspect.

    Args:
        configs: label or list of labels of `.editorconfig` / `.globalconfig` files
            passed to `csc` via `/analyzerconfig:`.
        analyzers: list of labels of additional Roslyn analyzer targets or `.dll`
            files (e.g. `@paket.main//roslynator.analyzers`).
        additionalfiles: list of labels of additional files passed to analyzers
            via `/additionalfile:`.
        enable_net_analyzers: whether to run the .NET SDK's built-in `CAxxxx`
            code quality analyzers (and Web SDK analyzers for web targets).
            Defaults to `True`.
        enforce_code_style: whether to run the .NET SDK's built-in `IDExxxx`
            C# code style and formatting analyzers. Defaults to `True`.
        analysis_mode: SDK analyzer severity preset (`default`, `none`,
            `minimum`, `recommended`, or `all`). Defaults to `"default"`.
        rule_kinds: which [kinds](https://bazel.build/query/language#kind) of
            rules should be visited by the aspect.
    """
    if type(configs) != "list":
        configs = [configs]

    return aspect(
        implementation = _csharp_analyzer_aspect_impl,
        attrs = {
            "_options": attr.label(
                default = "//lint:options",
                providers = [LintOptionsInfo],
            ),
            "_configs": attr.label_list(
                default = configs,
                allow_files = True,
            ),
            "_analyzers": attr.label_list(
                default = analyzers,
                allow_files = True,
            ),
            "_additionalfiles": attr.label_list(
                default = additionalfiles,
                allow_files = True,
            ),
            "_enable_net_analyzers": attr.bool(
                default = enable_net_analyzers,
            ),
            "_enforce_code_style": attr.bool(
                default = enforce_code_style,
            ),
            "_analysis_mode": attr.string(
                default = analysis_mode,
                values = ["default", "none", "minimum", "recommended", "all"],
            ),
            "_rule_kinds": attr.string_list(
                default = rule_kinds,
            ),
        },
        toolchains = [
            "@jq.bzl//jq/toolchain:type",
            _DOTNET_TOOLCHAIN_TYPE,
        ],
    )
