#!/usr/bin/bash

# Script to run Clippy for Rust-Analyzer in Bazel
# ===============================================
#
# When using Bazel with Rust-Analyzer, the default check-on-save 
# functionality is broken. This means that when you save a file, 
# the file is not automatically checked by Cargo or Clippy.
#
# This script is a workaround to run Clippy checks on save using Bazel.
#
#
# Copy this script
# ================
#
# Copy this script to your path and make sure it is executable.
#
# ```bash
# cp ./bazel_clippy_json.sh ~/.local/bin/bazel_clippy_json.sh
# chmod +x ~/.local/bin/bazel_clippy_json.sh
# ```
#
# Add the directory `~/.local/bin` to your PATH in your `.bashrc` or `.zshrc` file.
#
#
# Configure editor
# ================
#
# In your editor configuration, set the option 
# 
#   rust-analyzer.check.overrideCommand
#
# to `bazel_clippy_json.sh $saved_file`. For example, in VSCode:
#
# ```json
# {
#    "rust-analyzer.check.overrideCommand": [
#        "bazel_clippy_json.sh",
#        "$saved_file"
#    ],
# }
# ```


# Start function definitions 
# ==========================
#
# The following is an explanation on how this script works
# and a guide on using Clippy with Bazel.
#
# The input of this script should be an existing Rust file (in a Bazel project).
validate_file() {
    local file="$1"
    # Check if the file argument is provided and exists
    if [ -z "$file" ]; then
        display_error "No file specified. Please specify a Rust file to lint."
    elif [ ! -e "$file" ]; then
        display_error "File '$file' does not exist, so it cannot be linted."
    elif [[ "$file" != *.rs ]]; then
        display_error "File '$file' does not have a .rs extension. Please specify a Rust file."
    fi
}
#
# The functions in the rest of the document rely on relative paths.
# These paths are relative to the root of the Bazel project.
# 
# We use the presence of marker files to determine this root.
find_bazel_project_root() {
    local dir="$1"
    local marker_files=("WORKSPACE" "WORKSPACE.bazel" "MODULE.bazel")

    while [ "$dir" != "/" ]; do
        for marker_file in "${marker_files[@]}"; do
            if [ -f "$dir/$marker_file" ]; then
                echo "$dir"
                return 0
            fi
        done
        dir=$(dirname "$dir")
    done
    return 1
}
#
# To check for the minimal amount of compiler errors for a Rust file in Bazel.
basic_lint() {
    local bazel_target ="$1"
    echo "Linting Bazel target $bazel_target..."
    bazel build $bazel_target
}
#
# Clippy has more stylistic checks for Rust code.
clippy_lint() {
    local bazel_target="$1"
    echo "Looking for stylistic issues in Bazel target $bazel_target..."
    bazel build \
        --aspects=@rules_rust//rust:defs.bzl%rust_clippy_aspect \
        --output_groups=+clippy_checks \
        $bazel_target
}
#
#
# Linting one file
# ================
#
# The previous functions cannot be used to lint only one file. 
# We need to extract some kind of path that can be used by Bazel
# 
# Function to get the relative path within the Bazel workspace
get_relative_path() {
    local abs_path="$1"
    local workspace_root="$2"
    echo "${abs_path#"$workspace_root"/}"
}
# 
# Function to query the Bazel target for the specified file
get_bazel_target() {
    local relative_path="$1"
    local target
    target=$(bazel query "$relative_path")

    if [ -z "$target" ]; then
        display_error "Could not find a build target for $relative_path. Ensure the file is mentioned in a BUILD.bazel script."
    fi
    echo "$target"
}
#
# After calling the previous function we can call the next Bash function.
# 
# This Bash function takes a single Bazel file target as argument. 
# This means it won't work for build targets in general.
lint_file() {
    local file_target="$1"
    echo "Linting Bazel file target $file_target..."
    bazel build \
        --compile_one_dependency \
        $file_target
}
# Example usage
# =============
# 
# If the path to a BUILD.bazel file is `./super_module/module/BUILD.bazel` and
# this build file has a target that includes a file `file.rs`, then you can run
# 
# ```bash
# lint_file //super_module/module:file.rs
# ```
#
#
# Clippy for non-Cargo projects 
# =============================
#
# The previous functions cannot be used in combination with Rust-Analyzer yet, because
# it cannot read the plain-text output. We need to output compiler diagnostics in JSON format.
#
# Where could we get this information?
#
# Bazel Rust uses `clippy-driver`. The source code for `clippy-driver` is at
# https://github.com/rust-lang/rust-clippy/blob/25505302665a707bedee68ca1f3faf2a09f12c00/src/driver.rs
# 
# The information in the help page is limited:
#
# ```bash
# clippy-driver --help
# ```
#
# The output of `clippy-driver` can be formatted as JSON using
#
# ```bash
# clippy-driver --error-format=json file_in_cargo_project.rs
# ```
#
#
# Clippy-driver JSON output in Bazel
# ==================================
#
# You can use the JSON output option `clippy-driver` within Bazel. For this, use the function
json_lint_file() {
    local file_target="$1"
    echo "Linting target $file_target..."
    bazel build \
        --compile_one_dependency \
        --@rules_rust//:error_format=json \
        $file_target
}
#
#
# Stricter Clippy rules
# =====================
#
# By default, not all the rules are enabled in Clippy.
# There are more rules included in a separate group called `pedantic`.
# The full list of lints included in this group is available on 
#
#      https://rust-lang.github.io/rust-clippy/master/index.html?groups=pedantic
#
#
# Disabling lints individually
# ============================
#
# The easiest way to allow issues flagged by the Clippy linter
# is to use the `#[allow(clippy::pedantic)]` attribute in the Rust file.
#
#
# Managing lints per crate
# =========================
# 
# The easiest way to deny or allow code that triggers a Clippy warning is to add 
# at the top-level file of a Rust crate a module attribute such as:
#
# ```rust
# #![warn(
#     clippy::all,
#     clippy::restriction,
#     clippy::pedantic,
#     clippy::nursery,
#     clippy::cargo,
# )]
# ```
#
# Managing lints for in a workspace
# =================================
#
# If you don't want to add a macro attribute to the top of every 
# crate in your Bazel workspace, but you want to enable or disable
# lints, the you you have to change the way Bazel calls `clippy-driver`.
#
# To enable a lint in a non-Cargo project with name `clippy::pedantic`, 
# for example in Bazel, you have to use 
#
# ```bash
# clippy-driver -W clippy::pedantic file_in_cargo_project.rs
# ``` 
#
# The lint level can be changed with `A` for allow, `D` for deny, and `W` for warn.
# 
# Enabling lints in Bazel
# =======================
#
# Lints are enabled in Bazel by using `@rules_rust//:clippy_flags`. 
# You specify the lints by first specifying the level with `-W`
# and then the name of the lint.
# 
bazel_lint_pedantic() {
    local target="$1"
    echo "Pedantically linting Bazel target $target..."
    bazel build \
        --aspects=@rules_rust//rust:defs.bzl%rust_clippy_aspect \
        --output_groups=+clippy_checks \
        --@rules_rust//:clippy_flags="-Wclippy::pedantic" \
        $file_target
}
# You can add more lints by adding commas between them. 
# Additional lints may also weaken lints in previously enabled categories.
#
# In the following function we enable `pedantic` but disable some
# lints that would force major refactorings.
json_lint_slightly_pedantic() {
    local target="$1"
    echo "Slightly pedantically linting Bazel target $target..."
    bazel build \
        --aspects=@rules_rust//rust:defs.bzl%rust_clippy_aspect \
        --output_groups=+clippy_checks \
        --@rules_rust//:clippy_flags="-Wclippy::pedantic,-Dclippy::perf,-Dclippy::correctness,-Wclippy::suspicious,-Dclippy::complexity,-Dclippy::style,-Aclippy::missing_errors_doc,-Aclippy::missing_panics_doc,-Aclippy::semicolon_if_nothing_returned" \
        $target
}
# Unfortunately, it is not possible to split this string.
#
#
# Bazel shortcuts
# ===============
#
# If you don't want to copy-past the last command or use a Bash script, 
# you can use Bazel shortcuts to save time.
#
# For example, inside a `.bazelrc` file in the root of a Bazel workspace
# you can define a shortcut (called a "configuration" in Bazel) like
# 
# ```config
# build:clippy --output_groups=+clippy_checks
# ```
#
# You can use this Bazel shortcut in a terminal with working directory 
# inside the root of the Bazel workspace with a command like
# 
# ```bash
# bazel build --config=clippy //...
# ```
#
#
# Combine JSON output with pedantic lints
# =======================================
#
# You can combine the JSON output with the pedantic lints.
#
# If you already have a `.bazelrc` file with the following configuration,
# you have to remove the --aspects flag from the command below.
#
# ```config
# build --aspects=@rules_rust//rust:defs.bzl%rust_clippy_aspect
# ```
#
json_pedantic_lint() {
    local file_target="$1"
    echo "Linting Bazel file target $file_target..."
    bazel build \
        --aspects=@rules_rust//rust:defs.bzl%rust_clippy_aspect \
        --compile_one_dependency \
        --@rules_rust//:error_format=json \
        --output_groups=+clippy_checks \
        --@rules_rust//:clippy_flags="-Wclippy::pedantic,-Dclippy::perf,-Dclippy::correctness,-Wclippy::suspicious,-Dclippy::complexity,-Dclippy::style,-Aclippy::missing_errors_doc,-Aclippy::missing_panics_doc,-Aclippy::semicolon_if_nothing_returned" \
        "$file_target"
}
#
#
# Script cancellation mechanism
# =============================
# 
# In case this script is still running for a particular file, but we 
# save the file again, we want to cancel the previous run and start a new one. 
# To do this, we use a lock file in some temporary directory.
#
# Path to the lock file
LOCK_FILE="/tmp/lint_script.lock"
#
# Function to display an error message and exit
display_error() {
    echo "Error: $1"
    exit 1
}
#
# Function to create a lock file with the current PID
create_lock() {
    echo "$$" >"$LOCK_FILE"
}
#
# Function to check for an existing instance and kill it if necessary
check_and_kill_existing_instance() {
    if [ -f "$LOCK_FILE" ]; then
        local existing_pid
        existing_pid=$(cat "$LOCK_FILE")

        # Check if the process is still running
        if kill -0 "$existing_pid" 2>/dev/null; then
            echo "An existing instance (PID=$existing_pid) is running. Terminating it."
            kill "$existing_pid"
            wait "$existing_pid" 2>/dev/null # Wait for process to terminate
        fi
    fi

    # Create a new lock with the current PID
    create_lock
}
#
#
# Sript that runs Clippy for Rust-Analyzer in Bazel
# =================================================
#
# This main function applies the options explained above.
# It kills any running version of this script, then calls 
# the one of the linting functions above.

main() {
    # Ensure that only one instance of this script is running
    check_and_kill_existing_instance

    local file_path
    file_path=$(realpath "$1")

    validate_file "$file_path"

    # Find Bazel project root and validate presence
    local workspace_root
    workspace_root=$(find_bazel_project_root "$file_path")
    if [ -z "$workspace_root" ]; then
        display_error "No Bazel project detected containing $file_path. Ensure you are inside a Bazel workspace."
    fi

    # Go the workspace directory
    cd $workspace_root

    # Get relative path of file within the workspace
    local relative_path
    relative_path=$(get_relative_path "$file_path" "$workspace_root")

    # Query the Bazel target for the relative path and run linting
    local target
    target=$(get_bazel_target "$relative_path")
    json_pedantic_lint "$target"
}

# Run the main function with all script arguments
main "$@"

# Cleanup the lock file on exit
trap "rm -f $LOCK_FILE" EXIT
