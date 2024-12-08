open Mirage

(* Define the main unikernel entrypoint *)
let main = main "Unikernel.Main" (stackv4v6 @-> job)

(* Use the default network interface (Xen backend) *)
let net = default_network

(* 
   Define a static IPv4 configuration.
   ipv4_config requires a network prefix and an optional gateway.
   
   Here:
   - IP: 192.168.122.2
   - Netmask: 255.255.255.0 (i.e. /24)
   - Gateway: 192.168.122.1

   Convert IP/netmask to a prefix:
   "192.168.122.2/24" means the host's assigned IP is 192.168.122.2
   within the 192.168.122.0/24 network.
*)
let prefix = Ipaddr.V4.Prefix.of_string_exn "192.168.122.2/24"
let gateway = Some (Ipaddr.V4.of_string_exn "192.168.122.1")

(* Create the IPv4 configuration record *)
let ipv4_config : ipv4_config = { network = prefix; gateway }

(* Construct a stack with the given static IPv4 config *)
let stack =
   if "xen" = Sys.getenv "MODE"
    then generic_stackv4v6 ~ipv4_config net
   else generic_stackv4v6 net

(* Register the unikernel *)
let () = register "network" [ main $ stack ]
