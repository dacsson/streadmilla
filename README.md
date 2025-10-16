# What's that?

This is a garbage collector implementation for the Stella programming language.

It uses OCaml's C interface thanks to dune

## How to run

```make
make FILE=<file_name>
```

This will run `dune build` to build `gc.so` and then link provided file with it and runtime headers.

## Structure

```
├── dune-project
├── example_stella <-- some compiled Stella source files
│   └── ...
├── lib         <-- gc implementation
│   ├── ...
├── Makefile    <-- build and link with compiled Stella file (*.c)
├── README.md   <-- you are here
├── stella      <-- c bindings
│   ├── ...
└── test
    ├── ...
```

## GC algorithm

Well, my initial intent is to implement a treadmill GC algorithm.

## Reference

[The Treadmill: Real-Time Garbage Collection Without Motion Sickness, Henry G. Baker](https://trout.me.uk/gc/treadmill.pdf)
