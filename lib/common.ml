open Lwt.Syntax

(* Function to gracefully close all sockets *)
let close_all_sockets connections =
  Printf.printf "Received SIGTERM, shutting down, closing all sockets\n";
  flush stdout;
  Hashtbl.fold
    (fun _ connection acc ->
      Lwt.finalize
        (fun () -> H2_lwt_unix.Client.shutdown connection)
        (fun () -> acc))
    connections (Lwt.return ())

(* Signal handler for SIGTERM *)
let setup_signal_handler connections =
  let handle_signal _ =
    let* () = close_all_sockets connections in
    Lwt.return (exit 0)
  in
  let _ = Lwt_unix.on_signal Sys.sigterm (fun _ -> Lwt.async handle_signal) in
  ()
