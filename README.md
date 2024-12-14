### Core Raft Implementation
#### Build Instructions (Docker)
1. git clone https://github.com/sidsabh/MirageRaft.git && cd MirageRaft
2. (~2 MINUTES) sudo docker build -t mirage-raft . 
3. sudo docker run -it --network=host  mirage-raft
4. (POST-RUN) sudo docker rm -f $(sudo docker ps -aq)

#### Build Instructions (manual)
1. apt install opam (will also install ocaml) using [guide](https://ocaml.org/install#linux_mac_bsd). make sure ocamlc version >=4.14.0 (e.g., opam switch create 4.14.0 --yes)
2. opam install dune
3. opam install . --deps-only
4. make up (launches frontend)
5. run tests (demo [here](https://www.youtube.com/watch?v=o2JRtMvaK9s))



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
