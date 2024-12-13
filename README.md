### Core Raft Implementation
#### Build Instructions
1. apt install opam (will also install ocaml) using [guide](https://ocaml.org/install#linux_mac_bsd). make sure ocamlc version >=4.14.0 (e.g., opam switch create 4.14.0 --yes)
3. opam install dune
2. opam install . --deps-only
3. make up (launches frontend)
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
