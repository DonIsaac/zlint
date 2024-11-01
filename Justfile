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

# Build and run the linter
run:
    zig build run

# Build in debug mode
build:
    zig build

# Check for syntax and semantic errors
check:
    @echo "Checking for AST errors..."
    @for file in `git ls-files | grep '.zig'`; do zig ast-check "$file"; done
    zig build check

# Run a command in watch mode. Re-runs whenever a source file changes
watch cmd="check":
    git ls-files | entr -rc just clear-run {{cmd}}

# Run all tests
test:
    zig build test

# Format the codebase, writing changes to disk
fmt:
    zig fmt src/**/*.zig
    typos -w
# Like `fmt`, but exits when problems are found without modifying files
lint:
    zig fmt --check src/**/*.zig
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
    zig build run -- --print-ast > ./tmp/{{filename}}
    prettier --write ./tmp/{{filename}}
