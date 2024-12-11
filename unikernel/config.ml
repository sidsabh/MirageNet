open Mirage

let stack =
  if "xen" = Sys.getenv "MODE" then
    let ipv4_config : ipv4_config =
      {
        network = Ipaddr.V4.Prefix.of_string_exn "192.168.122.105/24";
        gateway = Some (Ipaddr.V4.of_string_exn "192.168.122.1");
      }
    in
    generic_stackv4v6 ~ipv4_config default_network
  else generic_stackv4v6 default_network
(* let http_server = cohttp_server @@ conduit_direct ~tls:false stack *)

let main =
  let packages =
    [
      package
        ~pin:
          "git+file:///home/sidsabh/code/dc/MirageNet/ocaml-protoc-plugin#unix-free"
        "ocaml-protoc-plugin";
      package "mirage-crypto-rng";
      package "h2-lwt";
      package "h2-mirage";
      package "grpc";
      package "grpc-lwt";
      (* package "tls-mirage"; *)
    ]
  in
  main "Unikernel.RaftServer" ~packages
    (random @-> time @-> pclock @-> stackv4v6 @-> job)

let () =
  register "raft"
    [ main $ default_random $ default_time $ default_posix_clock $ stack ]
