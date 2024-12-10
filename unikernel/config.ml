open Mirage

let ipv4_config : ipv4_config =
  {
    network = Ipaddr.V4.Prefix.of_string_exn "192.168.122.2/24";
    gateway = Some (Ipaddr.V4.of_string_exn "192.168.122.1");
  }

let stack =
  if "xen" = Sys.getenv "MODE" then
    generic_stackv4v6 ~ipv4_config default_network
  else generic_stackv4v6 default_network

let http_server = cohttp_server @@ conduit_direct ~tls:false stack

let packages = [
  package "h2";
  package "ocaml-protoc-plugin";
  package "mirage-crypto-rng";
]

let main =
  main ~packages "Unikernel.RaftServer" (time @-> pclock @-> http @-> job)

let () =
  register "raft" [ main $ default_time $ default_posix_clock $ http_server ]