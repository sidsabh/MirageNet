(lang dune 3.16)

(name MirageNet)

(generate_opam_files true)

(source
 (github sidsabh/MirageNet))

(license MIT)

(package
 (name MirageNet)
 (allow_empty)
 (synopsis "final project")
 (description "raft on stuff")
 (depends 
  ocaml 
  dune
  (fmt (>= 0.9.0))
  (logs (>= 0.7.0))
  (grpc-lwt (>= 0.1.0))
  (h2-lwt-unix (>= 0.9.0))
  (ocaml-protoc-plugin (>= 4.4.0))))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/reference/dune-project/index.html
