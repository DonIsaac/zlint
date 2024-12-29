## todo for this draft PR:

- windows implementation, possible still just using libc
- update relevant tests, add a fixture specific to user defined tests and test it

- instead of taking the .so path directly, take a .zig file and invoke the local zig compiler
  (via an optionally configured path) with something like:
  ```sh
    zig build-lib \
        -Mzlint=./path/to/zlint/installation/ABI.zig \
        -Muser_entry=USER_ZIG_FILE \
        --cache-dir=.zlint \
        ./path/to/zlint/installation/native_plugin_root.zig \
        ...
  ```
  to build the dynamic library at runtime with zig's built-in caching.

- make the ABI stable
- put this behind a flag --unsafe-allow-user-defined-rules

## potential future work:

- add wasm bindings, and support wasm based plugins with a template for building one in zig
  NOTE: it is not secure to compile user zig to wasm and then run it, I don't believe the zig
  compiler makes security guarantees for compiling code.
