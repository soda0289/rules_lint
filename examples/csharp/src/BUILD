load("@rules_dotnet//dotnet:defs.bzl", "csharp_binary", "csharp_library")

package(default_visibility = ["//visibility:public"])

csharp_binary(
    name = "hello_csharp",
    srcs = ["hello.cs"],
    target_frameworks = ["net9.0"],
)

csharp_library(
    name = "clean_lib",
    srcs = ["clean_lib.cs"],
    target_frameworks = ["net9.0"],
)

filegroup(
    name = "all",
    srcs = [
        ":clean_lib",
        ":hello_csharp",
    ],
)
