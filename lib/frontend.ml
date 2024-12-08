(* frontend.ml *)
open Grpc_lwt
open Lwt.Infix
open Lwt.Syntax
open Raftkv
open Ocaml_protoc_plugin
open Common

(* Constants*)
let timeout_duration = 0.3

(* Logging *)
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
  Logs.set_level (Some Common.log_level);
  (* Adjust the log level as needed *)
  let log = Logs.Src.create name ~doc:(Printf.sprintf "%s logs" name) in
  (module (val Logs.src_log log : Logs.LOG) : Logs.LOG)

module Log = (val setup_logs "frontend")

(* Global state *)
let num_servers = ref 0

let server_connections : (int, H2_lwt_unix.Client.t) Hashtbl.t =
  Hashtbl.create Common.max_connections

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

(* Generic Leader Request *)
let send_request_to_leader ~(rpc_name : string) ~service ~request
    ~extract_leader_info =
  let rec loop () =
    Log.debug (fun m ->
        m "%s: Trying raftserver%d as leader" rpc_name !leader_id);

    (* Define a timeout for the RPC call *)
    let timeout =
      Lwt_unix.sleep timeout_duration >>= fun () ->
      Lwt.fail_with
        (Printf.sprintf "%s: Timeout waiting for server %d" rpc_name !leader_id)
    in

    (* Attempt the RPC call *)
    let rpc_call =
      call_server_rpc ~server_id:!leader_id ~rpc_name ~service ~request
    in

    (* Use Lwt.pick to race the RPC call against the timeout *)
    Lwt.catch
      (fun () ->
        let* result = Lwt.pick [ timeout; rpc_call ] in
        match result with
        | Ok response, _ ->
            let wrong_leader, leader_hint = extract_leader_info response in
            if wrong_leader then (
              leader_id := int_of_string leader_hint;
              Log.debug (fun m ->
                  m "%s: Leader is wrong, trying raftserver%d" rpc_name
                    !leader_id);
              loop ())
            else (
              Log.debug (fun m ->
                  m "%s RPC to server %d successful" rpc_name !leader_id);
              Lwt.return response)
        | Error _, _ ->
            Log.debug (fun m ->
                m "%s RPC to server %d failed, trying next server" rpc_name
                  !leader_id);
            (* Move to the next server *)
            leader_id := (!leader_id mod !num_servers) + 1;
            loop ())
      (fun ex ->
        (* Handle timeouts and exceptions *)
        Log.debug (fun m ->
            m "%s RPC to server %d failed with: %s. Trying next server."
              rpc_name !leader_id (Printexc.to_string ex));
        (* Move to the next server *)
        leader_id := (!leader_id mod !num_servers) + 1;
        loop ())
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
      Log.debug (fun m -> m "Received %s request" rpc_name);

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
  let name = Printf.sprintf "raftserver%d" i in

  match Unix.fork () with
  | 0 ->
      Unix.execv "./bin/server"
        [| name; string_of_int i; string_of_int !num_servers |]
  | pid -> Log.debug (fun m -> m "Started %s with PID %d" name pid)

let connect_server i =
  let port = i - 1 + Common.start_server_ports in
  let* addresses =
    Lwt_unix.getaddrinfo Common.hostname (string_of_int port)
      [ Unix.(AI_FAMILY PF_INET) ]
  in
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.connect socket (List.hd addresses).Unix.ai_addr >>= fun () ->
  let error_handler _ = Log.err (fun m -> m "error") in
  let* connection =
    H2_lwt_unix.Client.create_connection ~error_handler socket
  in
  Hashtbl.add server_connections port connection;
  Lwt.return ()

let read_request buffer decode name =
  Reader.create buffer |> decode |> function
  | Ok v ->
      Log.debug (fun m -> m "Received %s request with arg: %d" name v);
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
  let* _ = Lwt_unix.sleep Common.startup_wait in
  for i = 1 to request do
    ignore (connect_server i)
  done;

  let reply =
    Raftkv.FrontEnd.StartRaft.Response.make ~wrongLeader:false ~error:"" ()
  in
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

let grpc_routes =
  Server.(v () |> add_service ~name:"raftkv.FrontEnd" ~service:frontend_service)

(* Main *)
let () =
  let port = Common.frontend_port in
  let listen_address = Unix.(ADDR_INET (inet_addr_loopback, port)) in
  Lwt.async_exception_hook := (fun exn ->
    Logs.err (fun m -> m "Unhandled Lwt exception: %s" (Printexc.to_string exn));
  );

  setup_signal_handler
    (fun () ->
      Log.info (fun m ->
          m "Received SIGTERM, shutting down, closing all sockets"))
    server_connections;

  (* Server that responds to RPC (listens on 8001)*)
  Lwt.async (fun () ->
      let server =
        H2_lwt_unix.Server.create_connection_handler ?config:None
          ~request_handler:(fun _ reqd ->
            Server.handle_request grpc_routes reqd)
          ~error_handler:(fun _ ?request:_ _ _ ->
            Log.err (fun m -> m "An error occurred while handling a request"))
      in
      let+ _server =
        Lwt_io.establish_server_with_client_socket listen_address server
      in
      Log.info (fun m -> m "Listening on port %i for grpc requests" port));

  (* while(1) *)
  let forever, _ = Lwt.wait () in
  Lwt_main.run forever
