# Use an OCaml base image
FROM ocaml/opam:debian-11-ocaml-4.14

# Set the working directory inside the container
WORKDIR /app

# Update system packages
RUN sudo apt-get update && sudo apt-get install -y \
    curl \
    protobuf-compiler \
    pkg-config
RUN opam install dune --yes


# Copy the MirageRaft project into the container
COPY . .
RUN sudo chown -R opam:opam /app


# Install dependencies from opam
RUN opam install . --deps-only --yes
RUN opam install fmt --yes

# Build the MirageRaft project
EXPOSE 7001:10000
RUN eval $(opam env) && make up
CMD bin/frontend