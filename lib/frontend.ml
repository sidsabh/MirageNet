(* frontend.ml *)
open Grpc_lwt
open Lwt.Infix
open Lwt.Syntax
open Raftkv
open Ocaml_protoc_plugin
open Common

(* Global state *)
let num_servers = ref 0
let server_connections : (int, H2_lwt_unix.Client.t) Hashtbl.t =
  Hashtbl.create 10
let leader_id = ref 1

(* Disable SIGPIPE in case server down *)
let () = Sys.set_signal Sys.sigpipe Sys.Signal_ignore

(* Call Server Get *)
let call_server_get server_id key client_id request_id =
  (* Setup Http/2 connection for RequestVote RPC *)
  let port = 9000 + server_id in
  let connection = Hashtbl.find server_connections port in
  let encode, decode = Service.make_client_functions Raftkv.KeyValueStore.get in
  let req =
    Raftkv.GetKey.make ~key ~clientId:client_id ~requestId:request_id ()
  in
  let enc = encode req |> Writer.contents in

  Grpc_lwt.Client.call ~service:"raftkv.KeyValueStore" ~rpc:"Get"
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
           | None -> Raftkv.KeyValueStore.Get.Response.make ()))
    ()

let send_get_request_to_leader key clientId requestId =
  (*  *)
  let rec loop () =
    let* res = call_server_get !leader_id key clientId requestId in
    match res with
    | Ok (res, _) ->
        (* Spec: frontend may have to query the servers to find out who the current leader is *)
        let wrong_leader = res.wrongLeader in
        let _error = res.error in
        let value = res.value in
        if wrong_leader then (
          leader_id := int_of_string value;
          Printf.printf "Get: Leader is wrong, trying raftserver%d\n" !leader_id;
          flush stdout;
          loop ())
        else (
          Printf.printf "Get RPC to server %d successful, value: %s\n"
            !leader_id value;
          flush stdout;
          Lwt.return res)
    | Error _ ->
        Printf.printf "Get RPC to server %d failed, trying next server\n"
          !leader_id;
        flush stdout;
        leader_id := !leader_id + 1;
        loop ()
  in
  loop ()

(* Decode the incoming GetKey request *)
let handle_get_request buffer =
  let decode, encode = Service.make_service_functions Raftkv.FrontEnd.get in

  let request =
    Reader.create buffer |> decode |> function
    | Ok v -> v
    | Error e ->
        failwith
          (Printf.sprintf "Could not decode GetKey request: %s"
             (Result.show_error e))
  in

  Printf.printf
    "Received Get request:\n\
     {\n\
     \t\"key\": \"%s\"\n\
     \t\"ClientId\": %d\n\
     \t\"RequestId\": %d\n\
     }\n"
    request.key request.clientId request.requestId;
  flush stdout;

  (* Find the leader *)
  let* res =
    send_get_request_to_leader request.key request.clientId
      request.requestId
  in
  let res_wrong_leader = res.wrongLeader in
  let res_error = res.error in
  let res_value = res.value in

  (* Reply to the client *)
  let reply =
    Raftkv.FrontEnd.Get.Response.make ~wrongLeader:res_wrong_leader
      ~error:res_error ~value:res_value ()
  in
  Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))

(* Call server put *)
let call_server_put server_id key value client_id request_id =
  (* Setup Http/2 connection for RequestVote RPC *)
  let port = 9000 + server_id in
  let connection = Hashtbl.find server_connections port in
  (* code generation for RequestVote RPC *)
  let encode, decode = Service.make_client_functions Raftkv.KeyValueStore.put in
  let req =
    Raftkv.KeyValue.make ~key ~value ~clientId:client_id ~requestId:request_id
      ()
  in
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

let send_put_request_to_leader key value clientId requestId =
  let rec loop () =
    let* res =
      call_server_put !leader_id key value clientId requestId
    in
    match res with
    | Ok (res, _) ->
        let wrong_leader = res.wrongLeader in
        let _error = res.error in
        let value = res.value in
        if wrong_leader then (
          leader_id := int_of_string value;
          Printf.printf "Leader is wrong, trying raftserver%d\n" !leader_id;
          flush stdout;
          loop ())
        else (
          Printf.printf "Put RPC to server %d successful, value: %s\n"
            !leader_id value;
          flush stdout;
          Lwt.return res)
    | Error _ ->
        Printf.printf "Put RPC to server %d failed, trying next server\n"
          !leader_id;
        flush stdout;
        leader_id := !leader_id + 1;
        loop ()
  in
  loop ()

(* Handle Put *)
let handle_put_request buffer =
  let decode, encode = Service.make_service_functions Raftkv.FrontEnd.put in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok v ->
      let key = v.key in
      let value = v.value in
      let clientId = v.clientId in
      let requestId = v.requestId in

      Printf.printf
        "Received Put request:\n\
         {\n\
         \t\"key\": \"%s\"\n\
         \t\"value\": \"%s\"\n\
         \t\"ClientId\": %d\n\
         \t\"RequestId\": %d\n\
         }\n"
        key value clientId requestId;
      flush stdout;

      (* Find the leader *)
      let* res =
        send_put_request_to_leader key value clientId requestId
      in
      let res_wrong_leader = res.wrongLeader in
      let res_error = res.error in
      let res_value = res.value in

      (* Reply to the client *)
      let reply =
        Raftkv.FrontEnd.Put.Response.make ~wrongLeader:res_wrong_leader
          ~error:res_error ~value:res_value ()
      in
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e ->
      failwith
        (Printf.sprintf "Error decoding Put request: %s" (Result.show_error e))

(* Handle Replace *)
(* TODO: Finish *)
let handle_replace_request buffer =
  let decode, encode = Service.make_service_functions Raftkv.FrontEnd.replace in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok v ->
      Printf.printf "Received Replace request with key: %s and value: %s\n"
        v.key v.value;
      flush stdout;
      let reply =
        Raftkv.FrontEnd.Replace.Response.make ~wrongLeader:false ~error:"" ()
      in
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e ->
      failwith
        (Printf.sprintf "Error decoding Replace request: %s"
           (Result.show_error e))

(* spawn server processes *)
let spawn_server i =
  let name = "raftserver" ^ string_of_int i in
  let command =
    Printf.sprintf
      "./bin/server %d %d %s 2>&1 | awk '{print \"raftserver%d: \" $0; \
       fflush()}' >> raft.log &"
      i !num_servers name i
  in
  ignore (Sys.command command)

let connect_server i =
  let port = i + 9000 in
  let* addresses =
    Lwt_unix.getaddrinfo  "localhost" (string_of_int port)
      [ Unix.(AI_FAMILY PF_INET) ]
  in
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.connect socket (List.hd addresses).Unix.ai_addr >>= fun () ->
  let error_handler _ = print_endline "error" in
  let* connection =
    H2_lwt_unix.Client.create_connection ~error_handler socket in
  Hashtbl.add server_connections port connection;
  Lwt.return ()

(* Handle StartRaft *)
let handle_start_raft_request buffer =
  let decode, encode =
    Service.make_service_functions Raftkv.FrontEnd.startRaft
  in
  let request =
    Reader.create buffer |> decode |> function
    | Ok v ->
        Printf.printf "Received StartRaft request with arg: %d\n" v;
        flush stdout;
        v
    | Error e ->
        failwith
          (Printf.sprintf "Error decoding StartRaft request: %s"
             (Result.show_error e))
  in
  num_servers := request;
  for i = 1 to request do
    ignore (spawn_server i);
  done;
  (* Wait for a half a sec for the other servers to spawn *)
  let* _ = Lwt_unix.sleep 0.5 in
  for i = 1 to request do
    ignore (connect_server i);
  done;


  let reply =
    Raftkv.FrontEnd.StartRaft.Response.make ~wrongLeader:false ~error:"" ()
  in
  Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))

(* Handle New Leader *)
let handle_new_leader_request buffer =
  let decode, encode =
    Service.make_service_functions Raftkv.FrontEnd.newLeader
  in
  let request =
    Reader.create buffer |> decode |> function
    | Ok v ->
        Printf.printf "Received NewLeader request with arg: %d\n" v;
        flush stdout;
        v
    | Error e ->
        failwith
          (Printf.sprintf "Error decoding NewLeader request: %s"
             (Result.show_error e))
  in
  leader_id := request;

  let reply = Raftkv.FrontEnd.NewLeader.Response.make () in
  Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))

(* Create FrontEnd service with all RPCs *)
let frontend_service =
  Server.Service.(
    v ()
    |> add_rpc ~name:"Get" ~rpc:(Unary handle_get_request)
    |> add_rpc ~name:"Put" ~rpc:(Unary handle_put_request)
    |> add_rpc ~name:"Replace" ~rpc:(Unary handle_replace_request)
    |> add_rpc ~name:"StartRaft" ~rpc:(Unary handle_start_raft_request)
    |> add_rpc ~name:"NewLeader" ~rpc:(Unary handle_new_leader_request)
    |> handle_request)

let grpc_routes =
  Server.(v () |> add_service ~name:"raftkv.FrontEnd" ~service:frontend_service)

(* Main *)
let () =
  let port = 8001 in
  let listen_address = Unix.(ADDR_INET (inet_addr_loopback, port)) in
  
  setup_signal_handler server_connections;

  (* Server that responds to RPC (listens on 8001)*)
  Lwt.async (fun () ->
      let server =
        H2_lwt_unix.Server.create_connection_handler ?config:None
          ~request_handler:(fun _ reqd ->
            Server.handle_request grpc_routes reqd)
          ~error_handler:(fun _ ?request:_ _ _ ->
            print_endline "an error occurred")
      in
      let+ _server =
        Lwt_io.establish_server_with_client_socket listen_address server
      in
      Printf.printf "Frontend service listening on port %i for grpc requests\n"
        port;
      flush stdout);

  (* while(1) *)
  let forever, _ = Lwt.wait () in
  Lwt_main.run forever
