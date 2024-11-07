(lang dune 3.16)

(name MirageNet)

(generate_opam_files true)

(source
 (github username/reponame))

(authors "Author Name")

(maintainers "Maintainer Name")

(license LICENSE)

(documentation https://url/to/documentation)

(package
 (name MirageNet)
 (allow_empty)
 (synopsis "A short synopsis")
 (description "A longer description")
 (depends 
  ocaml 
  dune
  (grpc-lwt (>= 0.1.0))
  (h2-lwt-unix (>= 0.9.0))
  (ocaml-protoc-plugin (>= 4.4.0)))
 (tags
  (topics "to describe" your project)))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/reference/dune-project/index.html
