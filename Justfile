#!/usr/bin/env -S just --justfile

set windows-shell := ["powershell"]
set shell := ["bash", "-cu"]

alias b  := build
alias c  := check
alias ck := check
alias f  := fmt
alias l  := lint
alias r  := run
alias t  := test
alias w  := watch

_default:
  @just --list -u

# Run CI checks locally. Run this before making a PR.
ready:
    git diff --name-only --exit-code
    just fmt
    zig build check
    zig build
    zig build test
    zig build test-e2e
    git status

# Build and run the linter
run *ARGS:
    zig build run {{ARGS}}

# Build in debug mode
build *ARGS:
    zig build --summary all {{ARGS}}

# Check for syntax and semantic errors
check:
    @echo "Checking for AST errors..."
    @for file in `git ls-files | grep '.zig$'`; do zig ast-check "$file"; done
    zig build check

# Run a command in watch mode. Re-runs whenever a source file changes
watch cmd="check":
    git ls-files | entr -rc just clear-run {{cmd}}

# Run all tests
test:
    zig build test --summary all

e2e:
    zig build test-e2e

# Format the codebase, writing changes to disk
fmt:
    zig fmt src/**/*.zig test/**/*.zig build.zig
    typos -w
# Like `fmt`, but exits when problems are found without modifying files
lint:
    zig fmt --check src/**/*.zig test/**/*.zig build.zig
    typos

# Remove build artifacts
clean:
    rm -rf zig-out .zig-cache

# Clear the screen, then run `zig build {{cmd}}`. Used by `just watch`.
clear-run cmd:
    @clear
    @zig build {{cmd}}


# temporary scripts for testing. Will be removed later
print-ast filename="ast.json":
    @mkdir -p tmp
    rm -f ./tmp/{{filename}}
    zig build run -Dsingle-threaded -- --print-ast > ./tmp/{{filename}}
    prettier --write ./tmp/{{filename}}

# Clone or update submodules
submodules:
    ./tasks/submodules.sh

clone-submodule dir url sha:
  cd {{dir}} || git init {{dir}}
  cd {{dir}} && git remote add origin {{url}} || true
  cd {{dir}} && git fetch --depth=1 origin {{sha}} && git reset --hard {{sha}}
