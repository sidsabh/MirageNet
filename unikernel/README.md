#### Unix (/unikernel)
Network will be localhost by default, command line arguments differentiate the Raft servers

#### Xen (/xen-unikernel)
Configuration is required:
1. Create a virbr0 interface if not already created by libvirt
```
sudo ip link add name virbr0 type bridge
sudo ip addr add 192.168.122.1/24 dev br0
sudo ip link set virbr0 up
```
2. Each Raft server has to be compiled with a different ipv4_config for its Stack where you pass a different ip addresss
```
let ipv4_config : ipv4_config =
  {
    network = Ipaddr.V4.Prefix.of_string_exn "192.168.122.<IP_ADDR_NUM>/24";
    gateway = Some (Ipaddr.V4.of_string_exn "192.168.122.1");
  }
```
3. Command line arguments will instruct each raft server to host on the provided network at a different port and Xen will configure the unikernel to utilize the interface
```
vif = [ 'bridge=virbr0' ]
```
