todo for this draft PR:

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

- make the function pointers use ABI stable types
