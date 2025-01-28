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

install dir="~/.bin":
    cp zig-out/bin/zlint {{dir}}/zlint

# Run CI checks locally. Run this before making a PR.
ready:
    git diff --name-only --exit-code
    zig build check
    zig build install codegen docs:rules
    just fmt
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
    zig build check
check-ast:
    @for file in `git ls-files | grep '.zig$' | grep --invert-match 'fail'`; do zig ast-check "$file"; done

# Run a command in watch mode. Re-runs whenever a source file changes
watch cmd="check":
    git ls-files | entr -rc just clear-run {{cmd}}

# Run unit tests
test:
    zig build test --summary all

# Run end-to-end tests
e2e *ARGS:
    zig build test-e2e {{ARGS}}

# Run and collect coverage for all tests
coverage:
    zig build
    mkdir -p ./.coverage
    kcov --include-path=src,test ./.coverage/test zig-out/bin/test
    kcov --include-path=src,test ./.coverage/test-utils zig-out/bin/test-utils
    kcov --include-path=src,test ./.coverage/test-e2e zig-out/bin/test-e2e
    kcov --include-path=src,test ./.coverage/test-zlint zig-out/bin/zlint || true
    kcov --merge ./.coverage/all ./.coverage/test ./.coverage/test-utils ./.coverage/test-e2e ./.coverage/test-zlint

# Run benchmarks. Optionally specify a `--release` mode.
bench mode="safe":
    @mkdir -p tmp
    zig build --release={{mode}}
    hyperfine --shell=none --warmup 2 --export-csv tmp/bench.csv 'zig-out/bin/zlint' 


# Format the codebase, writing changes to disk
fmt:
    zig fmt src test/harness build.zig build.zig.zon
    typos -w

# Like `fmt`, but exits when problems are found without modifying files
lint:
    zig fmt --check src test/harness build.zig build.zig.zon
    typos
    bunx oxlint@latest --format github  -D correctness -D suspicious -D perf

docs:
    zig build docs

codegen:
    zig build codegen

# Remove build and test artifacts
clean:
    rm -rf .zig-cache \
        zig-out/bin zig-out/lib zig-out/docs \
        .coverage

# Generate boilerplate code for a new rule
new-rule name:
    @if which bun > /dev/null; then \
        bun tasks/new-rule.ts {{name}}; \
    else \
        echo "Please install bun to use this command."; \
    fi
    just codegen
    zig fmt src/linter

# (MacOS only) sign binaries so they can be debugged and traced with Instruments
codesign cmd="./zig-out/bin/zlint" *ARGS="": (build ARGS)
    codesign --entitlements entitlements.dev.plist -fs - {{cmd}}

# (MacOS only) detect and debug memory leaks
leaks cmd="./zig-out/bin/zlint": (codesign cmd)
    just codesign {{cmd}}
    MallocStackLogging=true leaks -atExit -- {{cmd}}

# (MacOS only) trace a binary with Instruments
trace cmd="./zig-out/bin/zlint": (codesign cmd "--release=fast -Ddebug-release")
    @mkdir -p tmp
    @rm -rf ./tmp/trace.trace
    xcrun xctrace record --template "Time Profiler" --output ./tmp/trace.trace --launch {{cmd}}

# Clear the screen, then run `zig build {{cmd}}`. Used by `just watch`.
clear-run cmd:
    @clear
    @zig build {{cmd}}


# temporary scripts for testing. Will be removed later
print-ast source filename="ast.json":
    @mkdir -p tmp
    rm -f ./tmp/{{filename}}
    zig build run -Dsingle-threaded -- --print-ast {{source}} > ./tmp/{{filename}}
    prettier --ignore-path=.prettierignore --write ./tmp/{{filename}}

# Clone or update submodules
submodules:
    ./tasks/submodules.sh

clone-submodule dir url sha:
  cd {{dir}} || git init {{dir}}
  cd {{dir}} && git remote add origin {{url}} || true
  cd {{dir}} && git fetch --depth=1 origin {{sha}} && git reset --hard {{sha}}
