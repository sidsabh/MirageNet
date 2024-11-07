open Grpc_lwt
open Kvstore

(* Decode the incoming GetKey request *)
let handle_get_request _buffer =
  let open Ocaml_protoc_plugin in
  let open Kvstore in
  let _decode, encode = Service.make_service_functions FrontEnd.get in
  
  (* let request =
    Reader.create buffer |> decode |> function
    | Ok v -> v
    | Error e -> 
        failwith (Printf.sprintf "Could not decode GetKey request: %s" (Result.show_error e))
  in *)
  
  (* Simulate a "value" for the key request. In a real system, you'd look it up in a database. *)
  let value = "dummy_value_for_key" in
  
  (* Construct the reply *)
  let reply = FrontEnd.Get.Response.make ~wrongLeader:false ~error:"" ~value () in
  
  (* Return the response *)
  Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))

(* Create the service for the FrontEnd *)
let frontend_service =
  Server.Service.(
    v () 
    |> add_rpc ~name:"Get" ~rpc:(Unary handle_get_request) 
    |> handle_request)

(* Create the server to handle incoming requests *)
let server =
  Server.(
    v () 
    |> add_service ~name:"kvstore.FrontEnd" ~service:frontend_service)

let () =
let open Lwt.Syntax in
let port = 8080 in
let listen_address = Unix.(ADDR_INET (inet_addr_loopback, port)) in
Lwt.async (fun () ->
    let server =
      H2_lwt_unix.Server.create_connection_handler ?config:None
        ~request_handler:(fun _ reqd -> Server.handle_request server reqd)
        ~error_handler:(fun _ ?request:_ _ _ ->
          print_endline "an error occurred")
    in
    let+ _server =
      Lwt_io.establish_server_with_client_socket listen_address server
    in
    Printf.printf "Listening on port %i for grpc requests\n" port;
    print_endline "");

let forever, _ = Lwt.wait () in
Lwt_main.run forever


