(* frontend.ml *)
open Grpc_lwt
open Kvstore

(* Global vars *)
let num_servers = ref 0

(* Decode the incoming GetKey request *)
let handle_get_request buffer =
  let open Ocaml_protoc_plugin in
  let open Kvstore in
  let decode, encode = Service.make_service_functions FrontEnd.get in

  let request =
    Reader.create buffer |> decode |> function
    | Ok v -> v
    | Error e -> 
        failwith (Printf.sprintf "Could not decode GetKey request: %s" (Result.show_error e))
  in

  Printf.printf "Received Get request:\n{\n\t\"key\": \"%s\"\n\t\"ClientId\": %d\n\t\"RequestId\": %d\n}" request.key request.clientId request.requestId;
  flush stdout;

  let value = "Not Initialized" in

  let reply = FrontEnd.Get.Response.make ~wrongLeader:false ~error:"" ~value () in
  Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))

(* Handle Put *)
let handle_put_request buffer =
  let open Ocaml_protoc_plugin in
  let open Kvstore in
  let decode, encode = Service.make_service_functions FrontEnd.put in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok v ->

      Printf.printf "Received Put request:\n{\n\t\"key\": \"%s\"\n\t\"value\": \"%s\"\n\t\"ClientId\": %d\n\t\"RequestId\": %d\n}" v.key v.value v.clientId v.requestId;
      print_endline "";

      let reply = FrontEnd.Put.Response.make ~wrongLeader:false ~error:"" ~value:"Not Initialized"() in
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e -> failwith (Printf.sprintf "Error decoding Put request: %s" (Result.show_error e))

(* Handle Replace *)
let handle_replace_request buffer =
  let open Ocaml_protoc_plugin in
  let open Kvstore in
  let decode, encode = Service.make_service_functions FrontEnd.replace in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok v ->
      Printf.printf "Received Replace request with key: %s and value: %s\n" v.key v.value;
      let reply = FrontEnd.Replace.Response.make ~wrongLeader:false ~error:"" () in
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e -> failwith (Printf.sprintf "Error decoding Replace request: %s" (Result.show_error e))

(* spawn server processes *)
let spawn_server i =
  let command = Printf.sprintf 
    "./bin/server %d 2>&1 | awk '{print \"raftserver%d: \" $0; fflush()}' >> raft.log &"
    i i in
  ignore (Sys.command command)



(* Handle StartRaft *)
let handle_start_raft_request buffer =
  let open Ocaml_protoc_plugin in
  let open Kvstore in
  let decode, encode = Service.make_service_functions FrontEnd.startRaft in
  let request = 
    Reader.create buffer |> decode |> function
    | Ok v ->
      Printf.printf "Received StartRaft request with arg: %d\n" v;
      flush stdout;
      v
    | Error e -> failwith (Printf.sprintf "Error decoding StartRaft request: %s" (Result.show_error e))
  in
  num_servers := request;
  for i = 1 to request do
    ignore (spawn_server i)
  done;
  

  let reply = FrontEnd.StartRaft.Response.make ~wrongLeader:false ~error:"" () in
  Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
      
(* Create FrontEnd service with all RPCs *)
let frontend_service =
  Server.Service.(
    v () 
    |> add_rpc ~name:"Get" ~rpc:(Unary handle_get_request)
    |> add_rpc ~name:"Put" ~rpc:(Unary handle_put_request)
    |> add_rpc ~name:"Replace" ~rpc:(Unary handle_replace_request)
    |> add_rpc ~name:"StartRaft" ~rpc:(Unary handle_start_raft_request)
    |> handle_request)

let server =
  Server.(
    v ()
    |> add_service ~name:"kvstore.FrontEnd" ~service:frontend_service)


let () =
let open Lwt.Syntax in
let port = 8001 in
let listen_address = Unix.(ADDR_INET (inet_addr_loopback, port)) in
Lwt.async (fun () ->
    let server =
      H2_lwt_unix.Server.create_connection_handler ?config:None
        ~request_handler:(fun _ reqd -> Server.handle_request server reqd)
        ~error_handler:(fun _ ?request:_ _ _ -> print_endline "an error occurred")
    in
    let+ _server =
      Lwt_io.establish_server_with_client_socket listen_address server
    in
    Printf.printf "Frontend service listening on port %i for grpc requests\n" port;
    flush stdout);
let forever, _ = Lwt.wait () in
Lwt_main.run forever
