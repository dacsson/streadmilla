# What's this?

A garbage collector for [Stella](https://fizruk.github.io/stella/) programming language.

# Usage

## Prerequisites

You should have Zig installed. The latest version is mandatory. You can download pre-built binaries from [here](https://ziglang.org/download/).

Then check your version with `zig version`:
```
~  =>  zig version
0.16.0-dev.747+493ad58ff
```

It also depends on `translate_c` library of zig. Just for the sheer fact that *during this project I found an [actual bug](https://github.com/ziglang/translate-c/issues/211) in it*. Mind you, that is an official part of zig std/build system. Cool! The need for a dependency is because I had to make my work-around for it.

## Running

You can build binary from some `*.stella` files using the `Makefile`:
```
make FILE=<file_name>.stella
```

and then run it:
```
./build/<file_name>
```

> [!NOTE]
> Default build directory is `$(pwd)/build/`

Optionally you can set debug and statistics flags like this:
```
make FILE=<file_name>.stella DEBUG=1 GS_STATS=1 RT_STATS=1
```

Essentially it does three things:
1. `zig build` to build a library, that exports the `gc` function for C, obeying by `gc.h` interface (all runtime dependencies (*.c and *.h) are in `stella/` directory)
2. Compiles Stella file into a C code via docker
3. Links the library with the compiled C code from Stella source code into an executable
