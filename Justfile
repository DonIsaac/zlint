#!/usr/bin/env -S just --justfile

# Useful resources:
# - Justfile syntax cheatsheet: https://cheatography.com/linux-china/cheat-sheets/justfile/

set windows-shell := ["powershell"]
set shell := ["bash", "-cu"]

alias b   := build
alias c   := check
alias ck  := check
alias f   := fmt
alias l   := lint
alias r   := run
alias t   := test
alias w   := watch
alias cov := coverage

_default:
  @just --list -u

# Install necessary dev tools
init:
    ./tasks/init.sh

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

# Run unit tests
test:
    zig build test --summary all
# Run end-to-end tests
e2e:
    zig build test-e2e

# Run and collect coverage for all tests
coverage:
    zig build
    mkdir -p ./.coverage
    kcov --include-path=src,test ./.coverage/test zig-out/bin/test
    kcov --include-path=src,test ./.coverage/test-e2e zig-out/bin/test-e2e
    kcov --merge ./.coverage/all ./.coverage/test ./.coverage/test-e2e

# Format the codebase, writing changes to disk
fmt:
    zig fmt src/**/*.zig test/**/*.zig build.zig build.zig.zon
    typos -w
# Like `fmt`, but exits when problems are found without modifying files
lint:
    zig fmt --check src/**/*.zig test/**/*.zig build.zig build.zig.zon
    typos

# Remove build and test artifacts
clean:
    rm -rf .zig-cache \
        zig-out/bin zig-out/lib \
        .coverage

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
