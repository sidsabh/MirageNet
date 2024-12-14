### Core Raft Implementation
#### Build Instructions (Docker)
1. Get the code, build the container (~5 minutes)
```
git clone https://github.com/sidsabh/MirageRaft.git && cd MirageRaft
sudo docker build -t mirage-raft .
```
OR 
1. Pull the Docker image
```
docker pull sidsabh/mirage-raft:mirage-raft
```
2. Launch the frontend on the host network (blocking ports, spawning Raft Servers will all work per usual on localhost)
```
sudo docker run -it --network=host  mirage-raft #  sidsabh/mirage-raft:mirage-raft if you pulled from Docker Hub
```
3. Cleanup if a run is still holding a port
```
sudo docker rm -f $(sudo docker ps -aq)
```

#### Build Instructions (manual)
1. Install opam (includes OCaml compiler) via [guide](https://ocaml.org/install#linux_mac_bsd).  Make sure ocamlc version >=4.14 (e.g., opam switch create 4.14.0 --yes)
2. Install stuff from apt and opam:
```
sudo apt-get update && sudo apt-get install -y \
    curl \
    protobuf-compiler \
    pkg-config
opam install dune
opam install . --deps-only
opam install fmt --yes
```
3. Launch via
```
make up
```
4. run tests (demo [here](https://www.youtube.com/watch?v=o2JRtMvaK9s))



### Distributed Unikernels
#### Demos
1. [Working Processes Linux](https://www.youtube.com/watch?v=o2JRtMvaK9s)
2. [Working QEMU VM Linux](https://www.youtube.com/watch?v=FpxuH9PP_SM)
3. [Working Xen VM Linux](https://www.youtube.com/watch?v=9ootTDpPCHc)
4. [Working Unix Unikernel](https://www.youtube.com/watch?v=i4UQx420X9Y)
5. [Working Xen Unikernel](https://www.youtube.com/watch?v=7ogb8ENc1ZQ) (the coolest)

#### Benchmarks

![Workload Throughput Comparison](https://www.sidsabhnani.com/unikernel/unikernel_time.png)
![Workload Resource Comparison](https://www.sidsabhnani.com/unikernel/unikernel_resource.png)
