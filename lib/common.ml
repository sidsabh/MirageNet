open Lwt.Syntax

let hostname = "localhost"
let max_connections = 31
let start_bind_ports = 7001
let start_server_ports = 9001
let frontend_port = 8001
let startup_wait = 0.5
let log_level = Logs.Debug
let persist = true

(* Function to gracefully close all sockets *)
let close_all_sockets connections =
  Hashtbl.fold
    (fun _ connection acc ->
      Lwt.finalize
        (fun () -> H2_lwt_unix.Client.shutdown connection)
        (fun () -> acc))
    connections (Lwt.return ())

(* Signal handler for SIGTERM *)
let setup_signal_handler local_handler connections =
  let handle_signal _ =
    local_handler ();
    let* () = close_all_sockets connections in
    Lwt.return (exit 0)
  in
  let _ = Lwt_unix.on_signal Sys.sigterm (fun _ -> Lwt.async handle_signal) in
  ()
