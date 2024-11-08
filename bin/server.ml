(* server.ml *)
open Grpc_lwt
open Kvstore

(* Handle GetState *)
let handle_get_state_request buffer =
  let open Ocaml_protoc_plugin in
  let open Kvstore in
  let decode, encode = Service.make_service_functions KeyValueStore.getState in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok _ ->
      let reply = KeyValueStore.GetState.Response.make ~term:1 ~isLeader:true () in
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e -> failwith (Printf.sprintf "Error decoding GetState request: %s" (Result.show_error e))

(* Handle Get *)
let handle_get_request buffer =
  let open Ocaml_protoc_plugin in
  let open Kvstore in
  let decode, encode = Service.make_service_functions KeyValueStore.get in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok v ->
      Printf.printf "Received Get request for key: %s\n" v.key;
      let value = "dummy_value_for_key" in
      let reply = KeyValueStore.Get.Response.make ~wrongLeader:false ~error:"" ~value () in
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e -> failwith (Printf.sprintf "Error decoding Get request: %s" (Result.show_error e))

(* Handle Put *)
let handle_put_request buffer =
  let open Ocaml_protoc_plugin in
  let open Kvstore in
  let decode, encode = Service.make_service_functions KeyValueStore.put in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok v ->
      Printf.printf "Received Put request with key: %s and value: %s\n" v.key v.value;
      let reply = KeyValueStore.Put.Response.make ~wrongLeader:false ~error:"" () in
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e -> failwith (Printf.sprintf "Error decoding Put request: %s" (Result.show_error e))

(* Handle Replace *)
let handle_replace_request buffer =
  let open Ocaml_protoc_plugin in
  let open Kvstore in
  let decode, encode = Service.make_service_functions KeyValueStore.replace in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok v ->
      Printf.printf "Received Replace request with key: %s and value: %s\n" v.key v.value;
      let reply = KeyValueStore.Replace.Response.make ~wrongLeader:false ~error:"" () in
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e -> failwith (Printf.sprintf "Error decoding Replace request: %s" (Result.show_error e))

let key_value_store_service =
  Server.Service.(
    v ()
    |> add_rpc ~name:"GetState" ~rpc:(Unary handle_get_state_request)
    |> add_rpc ~name:"Get" ~rpc:(Unary handle_get_request)
    |> add_rpc ~name:"Put" ~rpc:(Unary handle_put_request)
    |> add_rpc ~name:"Replace" ~rpc:(Unary handle_replace_request)
    |> handle_request)

let server =
  Server.(
    v ()
    |> add_service ~name:"kvstore.KeyValueStore" ~service:key_value_store_service)

let () =
  let open Lwt.Syntax in
  let id = Sys.argv.(1) |> int_of_string in
  let port = 9000 + id in
  let listen_address = Unix.(ADDR_INET (inet_addr_loopback, port)) in
  let server_name = Printf.sprintf "raftserver%d" id in
  Lwt.async (fun () ->
      let server =
        H2_lwt_unix.Server.create_connection_handler ?config:None
          ~request_handler:(fun _ reqd -> Server.handle_request server reqd)
          ~error_handler:(fun _ ?request:_ _ _ -> print_endline "an error occurred")
      in
      let+ _server =
        Lwt_io.establish_server_with_client_socket listen_address server
      in
      Printf.printf "Server %s listening on port %i for grpc requests\n" server_name port;
      print_endline "Press Ctrl+C to stop");
  let forever, _ = Lwt.wait () in
  Lwt_main.run forever
