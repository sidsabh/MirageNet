BUILD INSTRUCTIONS!

1. apt install opam (will also install ocaml) (https://ocaml.org/install#linux_mac_bsd)
    1a. make sure ocamlc version >=4.14.0 (e.g., opam switch create 4.14.0 --yes)
2. opam install dune
2. opam install . --deps-only
3. make up (launches frontend)
4. run tests
