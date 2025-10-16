(lang dune 3.20)

(name streadmilla)

(generate_opam_files true)

(source
 (github dacsson/streadmilla))

(authors "Artjom Safonoff <sda20036@gmail.com>")

(maintainers "Just Me <sda20036@gmail.com>")

(license MIT)

(documentation https://url/to/documentation)

(package
 (name streadmilla)
 (synopsis "GC for Stella PL")
 (description "Treadmill GC for Stella PL")
 (depends ocaml)
 (allow_empty)
 (tags
  ("GC" "runtime")))
