(* frontend.ml *)
open Grpc_lwt
open Lwt.Infix
open Lwt.Syntax
open Raftkv

(* Global vars *)
let num_servers = ref 0
let leader_id = ref 1

(* Decode the incoming GetKey request *)
let handle_get_request buffer =
  let open Ocaml_protoc_plugin in
  let open Raftkv in
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

(* Call server put *)
let call_server_put address server_id key value client_id request_id =
  (* Setup Http/2 connection for RequestVote RPC *)
  let port = 9000 + server_id in
  Lwt_unix.getaddrinfo address (string_of_int port) [ Unix.(AI_FAMILY PF_INET) ]
  >>= fun addresses ->
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.connect socket (List.hd addresses).Unix.ai_addr
  >>= fun () ->
  let error_handler _ = print_endline "error" in
  H2_lwt_unix.Client.create_connection ~error_handler socket
  >>= fun connection ->

  (* code generation for RequestVote RPC *)
  let open Ocaml_protoc_plugin in
  let encode, decode = Service.make_client_functions Raftkv.KeyValueStore.put in
  let req = Raftkv.KeyValue.make ~key ~value ~clientId: client_id ~requestId: request_id () in 
  let enc = encode req |> Writer.contents in

  Grpc_lwt.Client.call ~service:"raftkv.KeyValueStore" ~rpc:"Put"
    ~do_request:(H2_lwt_unix.Client.request connection ~error_handler:ignore)
    ~handler:
      (Client.Rpc.unary enc ~f:(fun decoder ->
            let+ decoder = decoder in
            match decoder with
            | Some decoder -> (
                Reader.create decoder |> decode |> function
                | Ok v -> v
                | Error e ->
                    failwith
                      (Printf.sprintf "Could not decode request: %s"
                        (Result.show_error e)))
            | None -> Raftkv.KeyValueStore.Put.Response.make ()))
    ()
  

let send_put_request_to_leader address key value clientId requestId =
  let rec loop () =
    call_server_put address !leader_id key value clientId requestId >>= fun res ->
    match res with
    | Ok (res, _) -> 
      let wrong_leader = res.wrongLeader in
      let _error = res.error in
      let value = res.value in
      if wrong_leader then (
        leader_id := !leader_id + 1;
        Printf.printf "Leader is wrong, trying raftserver%d\n" !leader_id;
        flush stdout;
        loop ()
      ) else (
        Printf.printf "Put RPC to server %d successful, value: %s\n" !leader_id value;
        flush stdout;
        Lwt.return res
      )
    | Error _ -> 
      Printf.printf "Put RPC to server %d failed, trying next server\n" !leader_id;
      flush stdout;
      leader_id := !leader_id + 1;
      loop ()
  in
  loop ()

(* Handle Put *)
let handle_put_request buffer =
  let open Ocaml_protoc_plugin in
  let open Raftkv in
  let decode, encode = Service.make_service_functions FrontEnd.put in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok v ->
    let key = v.key in
    let value = v.value in
    let clientId = v.clientId in
    let requestId = v.requestId in

    Printf.printf "Received Put request:\n{\n\t\"key\": \"%s\"\n\t\"value\": \"%s\"\n\t\"ClientId\": %d\n\t\"RequestId\": %d\n}\n" key value clientId requestId;
    flush stdout;

    (* Find the leader *)
    let* res = send_put_request_to_leader "localhost" key value clientId requestId in
    let res_wrong_leader = res.wrongLeader in
    let res_error = res.error in
    let res_value = res.value in
    
    (* Reply to the client *)
    
    let reply = FrontEnd.Put.Response.make ~wrongLeader:res_wrong_leader ~error:res_error ~value:res_value() in
    Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e -> failwith (Printf.sprintf "Error decoding Put request: %s" (Result.show_error e))

(* Handle Replace *)
let handle_replace_request buffer =
  let open Ocaml_protoc_plugin in
  let open Raftkv in
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
    "./bin/server %d %d 2>&1 | awk '{print \"raftserver%d: \" $0; fflush()}' >> raft.log &"
    i !num_servers i in
  ignore (Sys.command command)



(* Handle StartRaft *)
let handle_start_raft_request buffer =
  let open Ocaml_protoc_plugin in
  let open Raftkv in
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
    |> add_service ~name:"raftkv.FrontEnd" ~service:frontend_service)

let () =
  let open Lwt.Syntax in
  let port = 8001 in
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
      Printf.printf "Frontend service listening on port %i for grpc requests\n" port;
      flush stdout);

  let forever, _ = Lwt.wait () in
  Lwt_main.run forever

