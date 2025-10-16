#include <stdlib.h>
#include <stdio.h>

#include "runtime.h"
#include "gc.h"

#include <caml/alloc.h>
#include <caml/mlvalues.h>
#include <caml/callback.h>

void __caml_init() {
    // Or pthread_once if you need it threadsafe.
    static int once = 0;

    if (once == 0) {
        // Fake an argv by prentending we're an executable `./ocaml_startup`.
        char* argv[] = {"ocaml_startup", NULL};

        // Initialize the OCaml runtime
        caml_startup(argv);

        once = 1;
    }
}

// #define NOT_IMPLEMENTED fprintf(stderr, "Function not implemented\n"); exit(EXIT_FAILURE);
CAMLprim value caml_not_implemented() {
    // Ensure the OCaml runtime is initialized before we invoke anything.
    __caml_init();

    // Fetch the function we registered via Callback.
    static const value* _Ocaml_unimplemented = NULL;
    if (_Ocaml_unimplemented == NULL)
      _Ocaml_unimplemented = caml_named_value("unimplemented");

    // Invoke the function, supplying () as the argument.
    caml_callback_exn(*_Ocaml_unimplemented, Val_unit);

    exit(EXIT_FAILURE);
}

#define NOT_IMPLEMENTED caml_not_implemented();

void* gc_alloc(size_t size) {
    NOT_IMPLEMENTED;
}

void gc_read_barrier(void *object, int field_index) {
    NOT_IMPLEMENTED;
}

void gc_write_barrier(void *object, int field_index, void *contents) {
    NOT_IMPLEMENTED;
}

void gc_push_root(void **object) {
    NOT_IMPLEMENTED;
}

void gc_pop_root(void **object) {
    NOT_IMPLEMENTED;
}

//========== HELPERS ==========

void print_gc_alloc_stats() {
    NOT_IMPLEMENTED;
}

void print_gc_state() {
    NOT_IMPLEMENTED;
}

void print_gc_roots() {
    NOT_IMPLEMENTED;
}
