open Lwt.Syntax

let hostname = "localhost"
let max_connections = 31
let start_bind_ports = 7001
let start_server_ports = 9001
let frontend_port = 8001
let log_level = Logs.Debug

(* Function to gracefully close all sockets *)
let close_all_sockets connections =
  Hashtbl.fold
    (fun _ connection acc ->
      Lwt.finalize
        (fun () -> H2_lwt_unix.Client.shutdown connection)
        (fun () -> acc))
    connections (Lwt.return ())

(* Signal handler for SIGTERM *)
let setup_signal_handler log connections =
  let handle_signal _ =
    log ();
    let* () = close_all_sockets connections in
    Lwt.return (exit 0)
  in
  let _ = Lwt_unix.on_signal Sys.sigterm (fun _ -> Lwt.async handle_signal) in
  ()

(* Signal handler for SIGTERM *)
let setup_logs name =
  (* Create a custom reporter with timestamps including microseconds and additional formatting *)
  let custom_reporter () =
    Logs_fmt.reporter
      ~pp_header:(fun ppf (level, _header) ->
        let time = Unix.gettimeofday () in
        let seconds = int_of_float time in
        let microseconds =
          int_of_float ((time -. float_of_int seconds) *. 1_000_000.)
        in
        let timestamp = Unix.gmtime time in
        let level_str = Logs.level_to_string (Some level) in
        Format.fprintf ppf "[%02d:%02d:%02d.%06d] [%s] [%s]: " timestamp.tm_hour
          timestamp.tm_min timestamp.tm_sec microseconds level_str name)
      ()
  in

  Logs.set_reporter (custom_reporter ());
  Logs.set_level (Some log_level);
  (* Adjust the log level as needed *)
  let log = Logs.Src.create name ~doc:(Printf.sprintf "%s logs" name) in
  (module (val Logs.src_log log : Logs.LOG) : Logs.LOG)
