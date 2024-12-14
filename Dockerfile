# Use an OCaml base image
FROM ocaml/opam:ubuntu-24.04-ocaml-4.14

# Set the working directory inside the container
WORKDIR /app
COPY . .
RUN sudo chown -R opam:opam .

# Update system packages
RUN sudo apt-get update && sudo apt-get install -y \
    curl \
    protobuf-compiler \
    pkg-config
RUN opam install dune --yes

# Copy the MirageRaft project into the container

# Install dependencies from opam
RUN opam install . --deps-only --yes
RUN opam install fmt --yes

# Build the MirageRaft project
EXPOSE 7001:10000
USER opam
RUN eval $(opam env) && make
CMD bin/frontend
