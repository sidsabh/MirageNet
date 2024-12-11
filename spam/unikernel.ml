open Cmdliner
open Ocaml_protoc_plugin
open Grpc_lwt
open Lwt.Syntax
open Lwt.Infix
open H2
open Raftkv
open Common

(* Runtime arguments *)
let port =
  let doc = Arg.info ~doc:"Port of HTTP service." [ "p"; "port" ] in
  Mirage_runtime.register_arg Arg.(value & opt int 8080 doc)


module RaftServer (R : Mirage_crypto_rng_mirage.S) (Time : Mirage_time.S) (Clock : Mirage_clock.PCLOCK) 
(Stack : Tcpip.Stack.V4V6)
= struct
  module TCP = Stack.TCP
  module Http2 = H2_mirage.Server (TCP)
  (* module Server = H2_mirage.Server (Gluten_mirage.Server (TCP)) *)

  (* Constants *)
  let heartbeat_timeout = 0.1
  let rpc_timeout = 0.1
  let election_timeout_floor = 0.3
  let election_timeout_additional = 0.3
  let majority_wait = 0.01

  (* Config *)
  let id = ref 0
  let num_servers = ref 0
  (* 
let server_connections : (int, H2_lwt_unix.Client.t) Hashtbl.t =
  Hashtbl.create Common.max_connections *)

  (* Persistent state on all servers *)
  let term = ref 69
  let voted_for = ref 0
  (* let log : Raftkv.LogEntry.t list ref = ref [] *)

  let log_entry_to_string (entry : Raftkv.LogEntry.t) =
    Printf.sprintf
      "\n\
       \t\t{\n\
       \t\t\t\"index\": %d\n\
       \t\t\t\"term\": %d\n\
       \t\t\t\"command\": \"%s\"\n\
       \t\t}"
      entry.index entry.term entry.command

  let kv_store : (string, string) Hashtbl.t = Hashtbl.create 10

  (* Volatile state on all servers *)
  let commit_index = ref (-1)
  let last_applied = ref (-1)

  (* Define the role type as an enumeration *)
  type role = Leader | Follower | Candidate

  let role_to_string = function
    | Leader -> "Leader"
    | Follower -> "Follower"
    | Candidate -> "Candidate"

  (* Atomic variable to store the current role *)
  let role = ref Follower

  let current_time () =
    let days, pico = Clock.now_d_ps () in
    (* Convert days and picoseconds to seconds since the epoch *)
    let seconds_since_epoch = Int64.add (Int64.of_int (days * 86_400)) (Int64.div pico 1_000_000_000_000L) in
    Int64.to_float seconds_since_epoch

  (* Initialize Logging *)
  let setup_logs name =
    (* Create a custom reporter with timestamps including microseconds and additional formatting *)
    let custom_reporter () =
      Logs_fmt.reporter
        ~pp_header:(fun ppf (level, _header) ->
          let days, ps = Clock.now_d_ps () in
          let time = Ptime.v (days, ps) in
          match Ptime.to_date_time time with
          (date, ((hour, min, sec), _)) ->
              let year, month, day = date in
              let microseconds = Int64.(to_int (div ps 1_000_000L) mod 1_000_000) in
              let level_str = Logs.level_to_string (Some level) in
              let current_term = !term in
              let current_role = role_to_string !role in
              Format.fprintf ppf
                "[%04d-%02d-%02d %02d:%02d:%02d.%06d] [%s] [%s|%s in Term %d]: "
                year month day hour min sec microseconds level_str name
                current_role current_term)
        ()
    in
  
  
  

  
    Logs.set_reporter (custom_reporter ());
    Logs.set_level (Some Common.log_level);
    (* Adjust the log level as needed *)
    let log = Logs.Src.create name ~doc:(Printf.sprintf "%s logs" name) in
    (module (val Logs.src_log log : Logs.LOG) : Logs.LOG)

  module Log = (val setup_logs ("raftserver" ^ string_of_int !id))

  (* Helper functions to log and manipulate the role *)

  let set_role new_role =
    let log_f = if !role = new_role then Log.info else fun _ -> () in
    log_f (fun m ->
        m "Changing role from %s to %s" (role_to_string !role)
          (role_to_string new_role));
    role := new_role

  let leader_id = ref 0
  let messages_recieved = ref false

  (* Volatile state on leaders *)
  let next_index : int list ref = ref []
  let match_index : int list ref = ref []

  (* Volatile state on candidates *)
  let votes_received : int list ref = ref []

  (* Global condition variable to trigger immediate heartbeat *)
  let send_entries_flag : unit Lwt_condition.t = Lwt_condition.create ()

  (* Global condition variable to trigger immediate election *)

  (* VM *)
  (* let get_vm_addr id =
    Unix.inet_addr_of_string (Printf.sprintf "192.168.100.%d" (id + 100))

  let get_vm_string id = Printf.sprintf "192.168.100.%d" (id + 100) *)

  let handle_get_state_request buffer =
    let decode, encode =
      Service.make_service_functions Raftkv.KeyValueStore.getState
    in
    let request = Reader.create buffer |> decode in
    match request with
    | Error e ->
        failwith
          (Printf.sprintf "Error decoding GetState request: %s"
             (Result.show_error e))
    | Ok _req ->
        (* Construct response *)
        let is_leader = (* determine if currently leader *) false in
        let response = Raftkv.State.make ~term:!term ~isLeader:is_leader () in
        Lwt.return
          (Grpc.Status.(v OK), Some (encode response |> Writer.contents))

  let key_value_store_service =
    Grpc_lwt.Server.Service.(
      v ()
      |> add_rpc ~name:"GetState" ~rpc:(Unary handle_get_state_request)
      (* Add other methods: Get, Put, Replace, RequestVote, AppendEntries *)
      |> handle_request)

  let grpc_routes =
    Grpc_lwt.Server.(
      v ()
      |> add_service ~name:"raftkv.KeyValueStore"
           ~service:key_value_store_service
      (* Add FrontEnd service if needed *))

  let key_value_store_service =
    Grpc_lwt.Server.Service.(
      v ()
      |> add_rpc ~name:"GetState" ~rpc:(Unary handle_get_state_request)
      (* |> add_rpc ~name:"Get" ~rpc:(Unary handle_get_request)
      |> add_rpc ~name:"Put" ~rpc:(Unary handle_put_request)
      |> add_rpc ~name:"Replace" ~rpc:(Unary handle_replace_request)
      (* RequestVote RPCs are initiated by candidates during elections *)
      |> add_rpc ~name:"RequestVote" ~rpc:(Unary handle_request_vote)
      (* AppendEntries RPCs are initiated by leaders to replicate log entries and to provide a form of heartbeat *)
      |> add_rpc ~name:"AppendEntries" ~rpc:(Unary handle_append_entries) *)
      |> handle_request)

  let grpc_routes =
    Grpc_lwt.Server.(
      v ()
      |> add_service ~name:"raftkv.KeyValueStore"
           ~service:key_value_store_service)

(* Define the request handler *)
  let request_handler reqd body =
    (* Dispatch gRPC or Raft logic here *)
    let open H2.Reqd in
    let response_body = "Hello, this is RaftServer!" in
    let headers =
      H2.Headers.of_list
        [ "content-length", string_of_int (String.length response_body) ]
    in
    respond_with_string reqd (Response.create ~headers `OK) response_body

  (* Define the error handler *)
  let error_handler ~request error =
    let response_body = "Internal server error" in
    let headers =
      H2.Headers.of_list
        [ "content-length", string_of_int (String.length response_body) ]
    in
    H2.Response.create ~headers `Internal_server_error


  let start _random _time _clock stack =
    (* Use the runtime argument for port *)
    let listening_port = port () in
    Logs.info (fun f -> f "Starting gRPC server on port %d" listening_port);

    let request_handler reqd = Server.handle_request grpc_routes reqd in

    let error_handler ?request:_ _error _ =
      Logs.err (fun f -> f "gRPC connection error")
    in

    (* Use the runtime argument for port *)
    let listening_port = port () in
    Logs.info (fun f -> f "Starting gRPC server on port %d" listening_port);
  
    let http2_handler =
      Http2.create_connection_handler ~request_handler ~error_handler
    in

    (* Listen for incoming TCP connections *)
    TCP.listen (Stack.tcp stack) ~port:listening_port (fun flow ->
        Logs.info (fun f -> f "Received new TCP connection");
        http2_handler flow);
    Stack.listen stack

end
