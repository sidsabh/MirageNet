(* bin/client.ml *)

open Cohttp_lwt_unix

(* Define the callback function to handle incoming requests *)
let server_callback _conn req _body =
  let uri = Cohttp.Request.uri req in
  let path = Uri.path uri in
  (* Log the request path to the console *)
  Printf.printf "Received request for path: %s\n" path;
  (* Respond with "Hello" *)
  Server.respond_string ~status:`OK ~body:"Hello" ()  (* No extra Lwt.return *)

(* Set up the server to listen on port 8000 *)
let start_server () =
  let port = 8000 in
  let config = Server.make ~callback:server_callback () in
  let mode = `TCP (`Port port) in
  Printf.printf "Server is listening on port %d\n%!" port;
  Server.create ~mode config

(* Run the server *)
let () =
  Lwt_main.run (start_server ())
