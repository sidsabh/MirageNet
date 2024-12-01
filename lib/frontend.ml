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

let call_server_rpc ~(server_id : int) ~(rpc_name : string) ~service ~request =
  let port = 9000 + server_id in
  let connection = Hashtbl.find server_connections port in
  let encode, decode = Service.make_client_functions service in
  let enc = encode request |> Writer.contents in

  let* result =
    Client.call ~service:"raftkv.KeyValueStore" ~rpc:rpc_name
      ~do_request:(H2_lwt_unix.Client.request connection ~error_handler:ignore)
      ~handler:
        (Client.Rpc.unary enc ~f:(fun decoder ->
             let+ decoder = decoder in
             match decoder with
             | Some decoder -> (
                 match Reader.create decoder |> decode with
                 | Ok v -> Ok v
                 | Error e ->
                     Error
                       (Grpc.Status.v ~message:(Result.show_error e)
                          Grpc.Status.Internal))
             | None ->
                 Error
                   (Grpc.Status.v ~message:"No response" Grpc.Status.Unknown)))
      ()
  in
  match result with
  | Ok (response, grpc_status) -> Lwt.return (response, grpc_status)
  | Error _h2_status ->
      Lwt.return
        ( Error
            (Grpc.Status.v ~message:"Invalid request"
               Grpc.Status.Invalid_argument),
          Grpc.Status.v ~message:"OK" Grpc.Status.OK )

(* Adjusted send_request_to_leader function *)
let send_request_to_leader ~(rpc_name : string) ~service ~request
    ~extract_leader_info =
  let rec loop () =
    let* result =
      call_server_rpc ~server_id:!leader_id ~rpc_name ~service ~request
    in
    match result with
    | Ok response, _ ->
        let wrong_leader, leader_hint = extract_leader_info response in
        if wrong_leader then (
          leader_id := int_of_string leader_hint;
          Printf.printf "%s: Leader is wrong, trying raftserver%d\n" rpc_name
            !leader_id;
          flush stdout;
          loop ())
        else (
          Printf.printf "%s RPC to server %d successful\n" rpc_name !leader_id;
          flush stdout;
          Lwt.return response)
    | Error _, _ ->
        Printf.printf "%s RPC to server %d failed, trying next server\n"
          rpc_name !leader_id;
        flush stdout;
        leader_id := (!leader_id mod !num_servers) + 1;
        loop ()
  in
  loop ()

(* Generic Request Handler *)
let handle_request ~(rpc_name : string) ~frontend_service ~backend_service
    ~build_backend_request
    ~(build_frontend_response : Raftkv.Reply.t -> 'backend_req)
    ~(extract_leader_info : Raftkv.Reply.t -> 'a) buffer =
  let decode_frontend, encode_frontend =
    Service.make_service_functions frontend_service
  in
  let request = Reader.create buffer |> decode_frontend in
  match request with
  | Ok frontend_req ->
      Printf.printf "Received %s request\n" rpc_name;
      flush stdout;

      let backend_request = build_backend_request frontend_req in
      let* backend_response =
        send_request_to_leader ~rpc_name ~service:backend_service
          ~request:backend_request ~extract_leader_info
      in
      let frontend_response = build_frontend_response backend_response in
      Lwt.return
        ( Grpc.Status.(v OK),
          Some (encode_frontend frontend_response |> Writer.contents) )
  | Error e ->
      failwith
        (Printf.sprintf "Error decoding %s request: %s" rpc_name
           (Result.show_error e))

(* Specific Handlers *)
let handle_get_request buffer =
  handle_request ~rpc_name:"Get" ~frontend_service:Raftkv.FrontEnd.get
    ~backend_service:Raftkv.KeyValueStore.get
    ~build_backend_request:(fun req ->
      Raftkv.GetKey.make ~key:req.key ~clientId:req.clientId
        ~requestId:req.requestId ())
    ~build_frontend_response:(fun res ->
      Raftkv.FrontEnd.Get.Response.make ~wrongLeader:res.wrongLeader
        ~error:res.error ~value:res.value ())
    ~extract_leader_info:(fun res -> (res.wrongLeader, res.value))
    buffer

let handle_put_request buffer =
  handle_request ~rpc_name:"Put" ~frontend_service:Raftkv.FrontEnd.put
    ~backend_service:Raftkv.KeyValueStore.put
    ~build_backend_request:(fun req ->
      Raftkv.KeyValue.make ~key:req.key ~value:req.value ~clientId:req.clientId
        ~requestId:req.requestId ())
    ~build_frontend_response:(fun res ->
      Raftkv.FrontEnd.Put.Response.make ~wrongLeader:res.wrongLeader
        ~error:res.error ~value:res.value ())
    ~extract_leader_info:(fun res -> (res.wrongLeader, res.value))
    buffer

let handle_replace_request buffer =
  handle_request ~rpc_name:"Replace" ~frontend_service:Raftkv.FrontEnd.replace
    ~backend_service:Raftkv.KeyValueStore.replace
    ~build_backend_request:(fun req ->
      Raftkv.KeyValue.make ~key:req.key ~value:req.value ~clientId:req.clientId
        ~requestId:req.requestId ())
    ~build_frontend_response:(fun res ->
      Raftkv.FrontEnd.Replace.Response.make ~wrongLeader:res.wrongLeader
        ~error:res.error ~value:res.value ())
    ~extract_leader_info:(fun res -> (res.wrongLeader, res.value))
    buffer

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
    Lwt_unix.getaddrinfo "localhost" (string_of_int port)
      [ Unix.(AI_FAMILY PF_INET) ]
  in
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.connect socket (List.hd addresses).Unix.ai_addr >>= fun () ->
  let error_handler _ = print_endline "error" in
  let* connection =
    H2_lwt_unix.Client.create_connection ~error_handler socket
  in
  Hashtbl.add server_connections port connection;
  Lwt.return ()

let read_request buffer decode name =
  Reader.create buffer |> decode |> function
  | Ok v ->
      Printf.printf "Received %s request with arg: %d\n" name v;
      flush stdout;
      v
  | Error e ->
      failwith
        (Printf.sprintf "Error decoding %s request: %s" name
           (Result.show_error e))

(* Handle StartRaft *)
let handle_start_raft_request buffer =
  let decode, encode =
    Service.make_service_functions Raftkv.FrontEnd.startRaft
  in
  let request = read_request buffer decode "StartRaft" in
  num_servers := request;
  for i = 1 to request do
    ignore (spawn_server i)
  done;
  (* Wait for a half a sec for the other servers to spawn *)
  let* _ = Lwt_unix.sleep 0.5 in
  for i = 1 to request do
    ignore (connect_server i)
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
  let request = read_request buffer decode "NewLeader" in
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
