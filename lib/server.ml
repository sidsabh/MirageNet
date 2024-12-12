(* server.ml *)
open Grpc_lwt
open Raftkv
open Ocaml_protoc_plugin
open Lwt.Syntax
open Lwt.Infix
open Common

(* Constants *)
let heartbeat_timeout = 0.1
let rpc_timeout = 0.1
let election_timeout_floor = 0.3
let election_timeout_additional = 0.3
let majority_wait = 0.01

(* Config *)
let id = ref 0
let num_servers = ref 0

let server_connections : (int, H2_lwt_unix.Client.t) Hashtbl.t =
  Hashtbl.create Common.max_connections

(* Persistent state on all servers *)
let term = ref 0
let voted_for = ref 0
let log : Raftkv.LogEntry.t list ref = ref []

let log_entry_to_string (entry : Raftkv.LogEntry.t) =
  Printf.sprintf
    "\n\
     \t\t{\n\
     \t\t\t\"index\": %d\n\
     \t\t\t\"term\": %d\n\
     \t\t\t\"command\": \"%s\"\n\
     \t\t}"
    entry.index entry.term entry.command

let kv_store = Hashtbl.create 100 (* Re-constructed *)

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

(* Helper functions to log and manipulate the role *)

(* Initialize Logging *)
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
        let current_term = !term in
        let current_role = role_to_string (!role) in
        Format.fprintf ppf "[%02d:%02d:%02d.%06d] [%s] [%s|%s in Term %d]: "
          timestamp.tm_hour timestamp.tm_min timestamp.tm_sec microseconds
          level_str name current_role current_term)
      ()
  in

  Logs.set_reporter (custom_reporter ());
  Logs.set_level (Some Common.log_level);
  (* Adjust the log level as needed *)
  let log = Logs.Src.create name ~doc:(Printf.sprintf "%s logs" name) in
  (module (val Logs.src_log log : Logs.LOG) : Logs.LOG)

module Log = (val setup_logs ("raftserver" ^ string_of_int !id))

let set_role new_role =
  let log_f = if !role = new_role then Log.info else fun _ -> () in
  log_f (fun m ->
      m "Changing role from %s to %s" (role_to_string (!role))
        (role_to_string new_role));
  role := new_role

let leader_id = ref 0
let messages_recieved = ref false

(* Volatile state on leaders *)
let next_index = ref []
let match_index = ref []

(* Volatile state on candidates *)
let votes_received : int list ref = ref []

(* Global condition variable to trigger immediate heartbeat *)
let send_entries_flag = Lwt_condition.create ()

(* File paths for persistence *)
let state_file_path server_id =
  Printf.sprintf "data/raft_server_%d_state.dat" server_id

(* State type for persistence *)
type persistent_state = {
  term : int;
  voted_for : int;
  log : Raftkv.LogEntry.t list;
}

(* SaveState on changes to term/votedfor/log[]*)
let save_state server_id =
  if Common.persist = false then Lwt.return_unit
  else
  let state = { term = !term; voted_for = !voted_for; log = !log } in
  let file_path = state_file_path server_id in
      Lwt_io.with_file ~mode:Lwt_io.Output file_path (fun channel ->
          let data = Marshal.to_bytes state [] in
          Lwt_io.write_from_string_exactly channel
            (Bytes.unsafe_to_string data)
            0 (Bytes.length data))

(* Load state from disk *)
let load_state server_id =
  let file_path = state_file_path server_id in
  if Sys.file_exists file_path then
    Lwt_io.with_file ~mode:Lwt_io.Input file_path (fun channel ->
        Lwt_io.read channel >>= fun data ->
        let state = Marshal.from_bytes (Bytes.of_string data) 0 in
            term := state.term;
            voted_for := state.voted_for;
            log := state.log;
            Lwt.return ())
  else Lwt.return_unit

let apply_commited_entries () =
  let rec loop i =
    if i <= !commit_index then (
      let entry = List.nth !log i in
      Log.info (fun m -> m "Applying log entry %d: %s" i entry.command);
      let key, value = Scanf.sscanf entry.command "%s %s" (fun k v -> (k, v)) in
      Hashtbl.replace kv_store key value;
      last_applied := i;
      loop (i + 1))
  in
  loop (!last_applied + 1)

let initialize_server_state server_id =
  load_state server_id >>= fun () ->
  Lwt.finalize
    (fun () ->
      apply_commited_entries ();
      Lwt.return_unit)
    (fun () -> save_state server_id)

let set_follower () =
  set_role Follower;
  voted_for := 0;
  votes_received := [];
  let* _ = save_state !id in
  (* UPDATE TO term/votedfor/log[]*)
  messages_recieved := true;
  Lwt.return ()

(* Function to handle higher term logic *)
let handle_higher_term new_term =
  if new_term > !term then (
    Log.debug (fun m ->
        m "Found higher term %d (current: %d). Resetting to follower." new_term
          !term);
    term := new_term;
    set_follower () >>= fun () -> Lwt.return_false)
  else Lwt.return_true (* Continue processing if no higher term *)

let rpc_with_timeout ~timeout_duration ~rpc_call ~log_error =
  let timeout =
    Lwt_unix.sleep timeout_duration >>= fun () -> Lwt.fail_with "RPC timeout"
  in
  Lwt.catch
    (fun () ->
      Lwt.pick [ rpc_call; timeout ] >>= function
      | Ok response -> Lwt.return (Ok response)
      | Error _ ->
          Lwt.return
            (Error (Grpc.Status.v ~message:"RPC failed" Grpc.Status.Unknown)))
    (fun _ex ->
      log_error ();
      Lwt.return
        (Error
           (Grpc.Status.v ~message:"RPC failed" Grpc.Status.Deadline_exceeded)))

(* Call NewLeaderRPC *)
let call_new_leader () =
  (* Setup Http/2 connection *)
  Lwt_unix.getaddrinfo "localhost" (string_of_int 8001) [ Unix.(AI_FAMILY PF_INET) ]
  >>= fun addresses ->
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.connect socket (List.hd addresses).Unix.ai_addr
  >>= fun () ->
  let error_handler _ = print_endline "error" in
  H2_lwt_unix.Client.create_connection ~error_handler socket
  >>= fun connection ->
(* Continue with the rest of your code using `connection` *)


  (* code generation *)
  let open Ocaml_protoc_plugin in
  let encode, decode = Service.make_client_functions Raftkv.FrontEnd.newLeader in
  let req = Raftkv.IntegerArg.make ~arg:!id () in 
  let enc = encode req |> Writer.contents in

  Client.call ~service:"raftkv.FrontEnd" ~rpc:"NewLeader"
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
            | None -> Raftkv.FrontEnd.NewLeader.Response.make ()))
    ()
          

(* Call AppendEntriesRPC with timeout handling *)
let call_append_entries port prev_log_index entries =
  let connection = Hashtbl.find server_connections port in

  let encode, decode =
    Service.make_client_functions Raftkv.KeyValueStore.appendEntries
  in
  let prev_log_term =
    if prev_log_index < List.length !log && prev_log_index >= 0 then
      (List.nth !log prev_log_index).term
    else 0
  in
  let req =
    Raftkv.AppendEntriesRequest.make ~term:!term ~leader_id:!id ~prev_log_index
      ~prev_log_term ~entries ~leader_commit:!commit_index ()
  in
  let enc = encode req |> Writer.contents in

  let rpc_call =
    Client.call ~service:"raftkv.KeyValueStore" ~rpc:"AppendEntries"
      ~do_request:(H2_lwt_unix.Client.request connection ~error_handler:ignore)
      ~handler:
        (Client.Rpc.unary enc ~f:(fun decoder ->
             let+ decoder = decoder in
             match decoder with
             | Some decoder -> (
                 Reader.create decoder |> decode |> function
                 | Ok v -> Ok v
                 | Error e ->
                     Error
                       (Grpc.Status.v ~message:(Result.show_error e)
                          Grpc.Status.Internal))
             | None ->
                 Error
                   (Grpc.Status.v ~message:"No response received"
                      Grpc.Status.Unknown)))
      ()
  in

  rpc_with_timeout ~timeout_duration:rpc_timeout ~rpc_call ~log_error:(fun () ->
      Log.debug (fun m ->
          m "AppendEntries RPC to server port %d failed: timeout" port))

let all_server_ids () =
  List.init !num_servers (fun i -> i + 1)
  |> List.filter (fun server_id -> server_id <> !id)

let try_update_commit_index () =
  (* If there exists an N such that N > commitIndex, a majority of matchIndex[i] ≥ N, and log[N].term == currentTerm: set commitIndex = N (§5.3, §5.4). *)
  (* try to continously update commit_index to commit_index+1 *)
  let condition_satisfied potential_index =
    let match_indices = List.map (fun x -> x >= potential_index) !match_index in
    let majority = (List.length match_indices / 2) + 1 in
    List.length (List.filter (fun x -> x) match_indices) >= majority
  in
  let rec loop () =
    if condition_satisfied (!commit_index + 1) then (
      commit_index := !commit_index + 1;
      apply_commited_entries ();
      loop ())
    else Lwt.return ()
  in
  loop ()

let rec send_to_follower follower_idx new_commit_index =
  (* last log index ≥ nextIndex for a follower: send AppendEntries RPC with log entries starting at nextIndex *)
  if !role <> Leader then Lwt.return_unit
  else
    let prev_log_index = List.nth !next_index follower_idx - 1 in
    let verify_index (entry : Raftkv.LogEntry.t) =
      entry.index > prev_log_index && entry.index <= new_commit_index
    in
    let new_entries = List.filter verify_index !log in
    let port = Common.start_server_ports + follower_idx in
    let* res = call_append_entries port prev_log_index new_entries in
    match res with
    | Ok (Ok v, _) ->
        if v.success then (
          (* If successful: update nextIndex and matchIndex for follower (§5.3) *)
          next_index :=
            List.mapi
              (fun i x -> if i = follower_idx then new_commit_index + 1 else x)
              !next_index;
          match_index :=
            List.mapi
              (fun i x -> if i = follower_idx then new_commit_index else x)
              !match_index;
          try_update_commit_index () >>= fun () ->
          Log.debug (fun m ->
              m
                (if new_entries = [] then "Heartbeat to server %d succeeded"
                 else "AppendEntries to server %d succeeded")
                (follower_idx + 1));
          Lwt.return_unit)
        else if
          (* If AppendEntries fails because of log inconsistency: decrement nextIndex and retry (§5.3) *)
          v.term > !term
        then (
          Log.debug (fun m ->
              m "AppendEntries to server %d failed (term mismatch)"
                (follower_idx + 1));
          let _ = handle_higher_term v.term in
          Lwt.return_unit)
        else (
          (* Decrement nextIndex and retry *)
          next_index :=
            List.mapi
              (fun i x -> if i = follower_idx then x - 1 else x)
              !next_index;
          Log.debug (fun m ->
              m "AppendEntries to server %d failed, retry with nextIndex: %d"
                (follower_idx + 1)
                (List.nth !next_index follower_idx));
          send_to_follower follower_idx new_commit_index)
    | Ok (Error grpc_status, _) ->
        Log.debug (fun m ->
            m "AppendEntries failed to server %d: %s" (follower_idx + 1)
              (Grpc.Status.show grpc_status));
        Lwt.return_unit
    | Error grpc_status ->
        Log.debug (fun m ->
            m "Communication error to server %d: %s" (follower_idx + 1)
              (Grpc.Status.show grpc_status));
        Lwt.return_unit

let send_updates_or_heartbeats () =
  let new_commit_index = List.length !log - 1 in
  Lwt_list.iter_p
    (fun server_id ->
      let follower_idx = server_id - 1 in
      send_to_follower follower_idx new_commit_index)
    (all_server_ids ())

(* Modified heartbeat loop *)
let heartbeat () =
  let rec heartbeat_loop () =
    Lwt.pick
      [
        (* Option 1: Triggered by client request *)
        ( Lwt_condition.wait send_entries_flag >>= fun () ->
          Log.debug (fun m -> m "appendEntries triggered by client request");
          send_updates_or_heartbeats () >>= fun () -> Lwt.return () );
        (* Option 2: Regular heartbeat timeout *)
        ( Lwt_unix.sleep heartbeat_timeout >>= fun () ->
          send_updates_or_heartbeats () >>= fun () ->
          Log.debug (fun m -> m "Sending heartbeats");
          Lwt.return () );
      ]
    >>= fun () ->
    if !role = Leader then heartbeat_loop () else Lwt.return ()
  in
  (* Send initial heartbeat then loop *)
  if !role = Leader then
    send_updates_or_heartbeats () >>= fun () -> heartbeat_loop ()
  else Lwt.return ()

(* Function to trigger the heartbeat loop immediately *)
let trigger_send_entries () = Lwt_condition.signal send_entries_flag ()

(* This function handles the request vote and counting the votes *)
let check_majority num_votes_received =
  let total_servers = !num_servers in
  let majority = (total_servers / 2) + 1 in
  if num_votes_received >= majority && !role = Candidate then (
    (* If we've received a majority, we win the election *)
    Log.debug (fun m ->
        m "We have a majority of votes (%d/%d) at term %d." num_votes_received
          total_servers !term);

    (* Become leader *)
    set_role Leader;
    leader_id := !id;
    let _res = call_new_leader () in
   
    (* Initialize nextIndex and matchIndex *)

    next_index := List.init !num_servers (fun _ -> List.length !log);
    match_index := List.init !num_servers (fun _ -> -1);

    (* Start sending heartbeats *)
    Lwt.async (fun () -> heartbeat ())
    (* TODO: only send during idle periods *)
    (* No need to return anything here; loops run asynchronously *))
  else
    Log.debug (fun m ->
        m "Votes received: %d, not enough for majority or already leader."
          num_votes_received)

(* Call RequestVoteRPC *)
let call_request_vote port candidate_id term last_log_index last_log_term =
  let connection = Hashtbl.find server_connections port in

  let encode, decode =
    Service.make_client_functions Raftkv.KeyValueStore.requestVote
  in
  let req =
    Raftkv.RequestVoteRequest.make ~candidate_id ~term ~last_log_index
      ~last_log_term ()
  in
  let enc = encode req |> Writer.contents in

  let rpc_call =
    Client.call ~service:"raftkv.KeyValueStore" ~rpc:"RequestVote"
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
                   (Grpc.Status.v ~message:"No response received"
                      Grpc.Status.Unknown)))
      ()
  in

  rpc_with_timeout ~timeout_duration:rpc_timeout ~rpc_call ~log_error:(fun () ->
      Log.debug (fun m ->
          m "RequestVote RPC to server port %d failed: timeout" port))

(* Updated send_request_vote_rpcs function *)
let send_request_vote_rpcs () =
  Lwt_list.iter_p
    (fun server_id ->
      if !role <> Candidate then Lwt.return_unit
      else
        let port = server_id - 1 + Common.start_server_ports in
        let candidate_id = !id in
        let term = !term in
        let log_length = List.length !log in
        let last_log_index = if log_length = 0 then 0 else log_length - 1 in
        let last_log_term =
          if log_length = 0 then 0 else (List.nth !log last_log_index).term
        in
        let* res =
          call_request_vote port candidate_id term last_log_index last_log_term
        in
        match res with
        | Ok (Ok response, _) ->
            let ret_term = response.term in
            let vote_granted = response.vote_granted in
            let* higher = handle_higher_term ret_term in
            if not higher then Lwt.return_unit
            else if vote_granted && not (List.mem server_id !votes_received)
            then (
              votes_received := server_id :: !votes_received;
              let num_votes_received = List.length !votes_received in
              check_majority num_votes_received;
              Lwt.return_unit)
            else Lwt.return_unit
        | Ok (Error grpc_status, _) ->
            Log.debug (fun m ->
                m "RequestVote RPC to server %d failed: %s" server_id
                  (Grpc.Status.show grpc_status));
            Lwt.return_unit
        | Error grpc_status ->
            Log.debug (fun m ->
                m "Communication error: %s" (Grpc.Status.show grpc_status));
            Lwt.return_unit)
    (all_server_ids ())

(* Attempt election *)
let attempt_election () =
  if (not !messages_recieved) && !role <> Leader then (
    set_role Candidate;
    term := !term + 1;
    Log.debug (fun m -> m "Attempting election at term %d" !term);
    voted_for := !id;
    let* _ = save_state !id in
    votes_received := [ !id ];
    send_request_vote_rpcs ())
  else Lwt.return ()

let election_timeout () =
  let timeout_duration =
    election_timeout_floor +. Random.float election_timeout_additional
  in
  Lwt_unix.sleep timeout_duration

(* Main loop for follower *)
let rec follower_loop () =
  messages_recieved := false;
  election_timeout () >>= fun () ->
  Lwt.pick [ attempt_election (); election_timeout () ] >>= fun () ->
  follower_loop ()

(* Handle GetState *)
let handle_get_state_request buffer =
  let decode, encode =
    Service.make_service_functions Raftkv.KeyValueStore.getState
  in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok _ ->
      let is_leader = !role = Leader in
      let reply =
        Raftkv.KeyValueStore.GetState.Response.make ~term:!term
          ~isLeader:is_leader ()
      in
      Log.info (fun m ->
          m "Received GetState request, replying with term %d and isLeader %b"
            !term is_leader);
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e ->
      failwith
        (Printf.sprintf "Error decoding GetState request: %s"
           (Result.show_error e))

let append_entry key value =
  let command = key ^ " " ^ value in
  let _ =
  let index = List.length !log in
  let new_log_entry =
    Raftkv.LogEntry.make ~term:!term ~command ~index ()
  in
  log := !log @ [ new_log_entry ];
  in
  let* _ = save_state !id in
  Lwt.return ()

let append_and_replicate key value =
  let* () = append_entry key value in
  let new_entry_index = List.length !log - 1 in
  (* update my match index: *)
  match_index :=
    List.mapi
      (fun i x -> if i = !id - 1 then new_entry_index else x)
      !match_index;
  (* If there exists an N such that N > commitIndex, a majority of matchIndex[i] ≥ N, and log[N].term == currentTerm: set commitIndex = N (§5.3, §5.4). *)
  let condition_satisfied () =
    let match_indices = List.map (fun x -> x >= new_entry_index) !match_index in
    let majority = (List.length match_indices / 2) + 1 in
    Log.debug (fun m ->
      m "Checking if condition is satisfied for commit index update");
    List.length (List.filter (fun x -> x) match_indices) >= majority
  in
  trigger_send_entries ();
  let rec wait_for_condition () =
    if condition_satisfied () then Lwt.return ()
    else if !role <> Leader then Lwt.return ()
    else Lwt_unix.sleep majority_wait >>= fun () -> wait_for_condition ()
  in
  let* () = wait_for_condition () in
  commit_index := new_entry_index;
  apply_commited_entries ();
  Lwt.return ()

(* Generic function to handle write requests like Put/Replace *)
let handle_write_request ~op_name ~service_decode_encode ~make_response
    ~process_key_value buffer =
  let decode, encode = service_decode_encode in
  match Reader.create buffer |> decode with
  | Error e ->
      failwith
        (Printf.sprintf "Error decoding %s request: %s" op_name
           (Result.show_error e))
  | Ok (v : Raftkv.KeyValue.t) ->
      let req_key = v.key in
      let req_value = v.value in
      let req_client_id = v.clientId in
      let req_request_id = v.requestId in

      let* (reply : Raftkv.KeyValueStore.Put.Response.t) =
        if !role <> Leader then
          let correct_leader = string_of_int !leader_id in
          Lwt.return
            (make_response ~wrongLeader:true ~error:"" ~value:correct_leader)
        else
          let value = process_key_value req_key req_value in
          let* _ = append_and_replicate req_key req_value in
          if !role = Leader then
            Lwt.return
              (make_response ~wrongLeader:false ~error:"" ~value)
          else
            (* Short circuited, never could enforce commit, not leader anymore *)
            Lwt.return
              (make_response ~wrongLeader:true ~error:"" ~value:(string_of_int !leader_id))
      in

      Log.info (fun m ->
          m
            "Received %s request:\n\
             {\n\
             \t\"key\": \"%s\"\n\
             \t\"value\": \"%s\"\n\
             \t\"clientId\": %d\n\
             \t\"requestId\": %d\n\
             \t\"response_value\": \"%s\"\n\
             \t\"wrongLeader\": %b\n\
             }"
            op_name req_key req_value req_client_id req_request_id reply.value
            reply.wrongLeader);
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))

(* Handle Put *)
let handle_put_request buffer =
  let process_key_value req_key _req_value =
    try
      let already = Hashtbl.find kv_store req_key in
      "ERROR: already in KV store, value=" ^ already
    with Not_found -> "Success"
  in
  handle_write_request ~op_name:"Put"
    ~service_decode_encode:
      (Service.make_service_functions Raftkv.KeyValueStore.put)
    ~make_response:(fun ~wrongLeader ~error ~value ->
      Raftkv.KeyValueStore.Put.Response.make ~wrongLeader ~error ~value ())
    ~process_key_value buffer

(* Handle Replace *)
let handle_replace_request buffer =
  let process_key_value req_key _req_value =
    try
      let old_val = Hashtbl.find kv_store req_key in
      "Old key:" ^ old_val
    with Not_found -> "SYSERROR: Key not found"
  in
  handle_write_request ~op_name:"Replace"
    ~service_decode_encode:
      (Service.make_service_functions Raftkv.KeyValueStore.replace)
    ~make_response:(fun ~wrongLeader ~error ~value ->
      Raftkv.KeyValueStore.Replace.Response.make ~wrongLeader ~error ~value ())
    ~process_key_value buffer

(* Handle Get *)
let handle_get_request buffer =
  let decode, encode =
    Service.make_service_functions Raftkv.KeyValueStore.get
  in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok v ->
      let reply =
        if !role <> Leader then
          let correct_leader = string_of_int !leader_id in
          Raftkv.KeyValueStore.Get.Response.make ~wrongLeader:true ~error:""
            ~value:correct_leader ()
        else
          let value =
            try
              Hashtbl.find kv_store v.key
              (* with Not_found -> failwith "Key not found" *)
            with Not_found -> "Key not found"
          in
          Raftkv.KeyValueStore.Get.Response.make ~wrongLeader:false ~error:""
            ~value ()
      in
      Log.info (fun m ->
          m
            "Received get request:\n\
             {\n\
             \t\"key\": \"%s\"\n\
             \t\"clientId\": %d\n\
             \t\"requestId\": %d\n\
             \t\"wrongLeader\": %b\n\
             \t\"response_value\": \"%s\"\n\
             }"
            v.key v.clientId v.requestId reply.wrongLeader reply.value);
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e ->
      failwith
        (Printf.sprintf "Error decoding Get request: %s" (Result.show_error e))

(* Handle RequestVoteRPC *)
let handle_request_vote buffer =
  let decode, encode =
    Service.make_service_functions Raftkv.KeyValueStore.requestVote
  in
  let request = Reader.create buffer |> decode in
  match request with
  | Error e ->
      failwith
        (Printf.sprintf "Error decoding RequestVote request: %s"
           (Result.show_error e))
  | Ok v ->
      let req_candidate_id = v.candidate_id in
      let req_term = v.term in
      let req_last_log_index = v.last_log_index in
      let req_last_log_term = v.last_log_term in

      let log_length = List.length !log in
      let last_log_term =
        if log_length = 0 then 0 else (List.nth !log (log_length - 1)).term
      in

      let log_is_up_to_date =
        req_last_log_term > last_log_term
        || req_last_log_term = last_log_term
           && req_last_log_index >= log_length - 1
      in

      let is_term_stale = req_term < !term in
      let has_voted_conflict =
        !voted_for <> 0 && !voted_for <> req_candidate_id
      in
      let _ = handle_higher_term req_term in

      let vote_granted, updated_term =
        match (is_term_stale, has_voted_conflict, log_is_up_to_date) with
        | true, _, _ -> (false, !term)
        | false, true, _ -> (false, !term)
        | false, false, false -> (false, !term)
        | false, false, true ->
            messages_recieved := true;
            voted_for := req_candidate_id;
            (true, max req_term !term)
      in

      let reply =
        Raftkv.KeyValueStore.RequestVote.Response.make ~vote_granted
          ~term:updated_term ()
      in

      Log.debug (fun m ->
          m
            "RequestVote Decision Summary:\n\
             {\n\
             \t\"candidate_id\": %d,\n\
             \t\"request_term\": %d,\n\
             \t\"last_log_index\": %d,\n\
             \t\"last_log_term\": %d,\n\
             \t\"log_length\": %d,\n\
             \t\"log_term\": %d,\n\
             \t\"log_is_up_to_date\": %b,\n\
             \t\"current_term\": %d,\n\
             \t\"voted_for\": %d,\n\
             \t\"vote_granted\": %b\n\
             }"
            req_candidate_id req_term req_last_log_index req_last_log_term
            log_length last_log_term log_is_up_to_date !term !voted_for
            vote_granted);

      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))

(* Handle AppendEntriesRPC *)
let handle_append_entries buffer =
  let decode, encode =
    Service.make_service_functions Raftkv.KeyValueStore.appendEntries
  in
  let request = Reader.create buffer |> decode in

  match request with
  | Error e ->
      failwith
        (Printf.sprintf "Error decoding AppendEntries request: %s"
           (Result.show_error e))
  | Ok v ->
      let req_term = v.term in
      let req_leader_id = v.leader_id in
      let req_prev_log_index = v.prev_log_index in
      let req_prev_log_term = v.prev_log_term in
      let req_entries = v.entries in
      let req_leader_commit = v.leader_commit in

      let is_heartbeat = req_entries = [] in
      let stale_term = req_term < !term in
      let log_mismatch =
        req_prev_log_index <> -1
        && (List.length !log <= req_prev_log_index
           || (List.nth !log req_prev_log_index).term <> req_prev_log_term)
      in

      (* Determine overall action based on conditions *)
      let action =
        match (stale_term, log_mismatch) with
        | true, _ ->
            (* §5.1: stale term -> reject *)
            `Reject
        | false, true ->
            (* §5.3: log mismatch -> reject *)
            `Reject
        | false, false ->
            (* Heartbeat with no stale term and no mismatch *)
            (* If this heartbeat introduces a new leader or confirms existing one *)
            if !role = Leader && !term = req_term then
              failwith "Multiple leaders in the same term, SYSERROR";
            leader_id := req_leader_id;
            term := req_term;
            ignore (set_follower ());
            if is_heartbeat then
              `Accept_no_entries
            (* Normal AppendEntries with entries *)
            else 
              `Append_entries
      in

      let reply =
        match action with
        | `Reject ->
            (* Return immediately with success=false *)
            Raftkv.KeyValueStore.AppendEntries.Response.make ~term:!term
              ~success:false ()
        | `Accept_no_entries ->
            (* Heartbeat accepted: no log mismatch, same or new leader recognized *)
            (* Still perform leaderCommit update if needed below *)
            (* success = true *)
            Raftkv.KeyValueStore.AppendEntries.Response.make ~term:!term
              ~success:true ()
        | `Append_entries ->
            (* Steps 3-5: Truncate conflict, append entries, update commit index *)
            let truncate_log_if_conflict (log : Raftkv.LogEntry.t list)
                (entries : Raftkv.LogEntry.t list) (prev_log_index : int) :
                Raftkv.LogEntry.t list =
              let rec loop (i : int) : Raftkv.LogEntry.t list =
                if
                  i >= List.length log
                  || i - prev_log_index - 1 >= List.length entries
                then log
                else
                  let log_term = (List.nth log i).term in
                  let entry_term =
                    (List.nth entries (i - prev_log_index - 1)).term
                  in
                  if log_term <> entry_term then
                    List.filteri (fun idx _ -> idx < i) log (* Truncate *)
                  else loop (i + 1)
              in
              loop (prev_log_index + 1)
            in

            let rec drop n lst =
              if n <= 0 then lst
              else match lst with [] -> [] | _ :: tail -> drop (n - 1) tail
            in

            (* Update log - first truncate our log if not matching, then only add the new entries *)
            log := truncate_log_if_conflict !log req_entries req_prev_log_index;
            let new_log_length = List.length !log in
            if new_log_length < req_prev_log_index + List.length req_entries + 1
            then (
              let new_entries =
                drop (new_log_length - (req_prev_log_index + 1)) req_entries
              in
              log := !log @ new_entries;
              ignore (save_state !id));

            if req_leader_commit > !commit_index then (
              let new_commit_index =
                min req_leader_commit (List.length !log - 1)
              in
              commit_index := new_commit_index;
              apply_commited_entries ());

            Raftkv.KeyValueStore.AppendEntries.Response.make ~term:!term
              ~success:true ()
      in

      (* Even if no entries, a heartbeat can still update commitIndex. So we re-check commit conditions after action. *)
      (* If `Accept_no_entries`, we also perform step 5 if leaderCommit advanced. *)
      if action = `Accept_no_entries && req_leader_commit > !commit_index then (
        let new_commit_index = min req_leader_commit (List.length !log - 1) in
        commit_index := new_commit_index;
        apply_commited_entries ());

      (* Logging summary only if entries were sent or something changed *)
      let log_f = if not is_heartbeat then Log.info else fun _ -> () in
      log_f (fun m ->
          m
            "AppendEntries Summary:\n\
             {\n\
             \t\"received_term\": %d,\n\
             \t\"received_leader_id\": %d,\n\
             \t\"received_prev_log_index\": %d,\n\
             \t\"received_prev_log_term\": %d,\n\
             \t\"received_entries\": [%s\n\
             \t],\n\
             \t\"received_leader_commit\": %d,\n\
             \t\"current_term\": %d,\n\
             \t\"current_leader_id\": %d,\n\
             \t\"log_length\": %d,\n\
             \t\"commit_index\": %d,\n\
             \t\"success\": %b\n\
             }"
            req_term req_leader_id req_prev_log_index req_prev_log_term
            (String.concat ", " (List.map log_entry_to_string req_entries))
            req_leader_commit !term !leader_id (List.length !log) !commit_index
            reply.success);

      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))

let key_value_store_service =
  Server.Service.(
    v ()
    |> add_rpc ~name:"GetState" ~rpc:(Unary handle_get_state_request)
    |> add_rpc ~name:"Get" ~rpc:(Unary handle_get_request)
    |> add_rpc ~name:"Put" ~rpc:(Unary handle_put_request)
    |> add_rpc ~name:"Replace" ~rpc:(Unary handle_replace_request)
    (* RequestVote RPCs are initiated by candidates during elections *)
    |> add_rpc ~name:"RequestVote" ~rpc:(Unary handle_request_vote)
    (* AppendEntries RPCs are initiated by leaders to replicate log entries and to provide a form of heartbeat *)
    |> add_rpc ~name:"AppendEntries" ~rpc:(Unary handle_append_entries)
    |> handle_request)

let grpc_routes =
  Server.(
    v ()
    |> add_service ~name:"raftkv.KeyValueStore" ~service:key_value_store_service)

let start_server () =
  let port = !id - 1 + Common.start_server_ports in
  let listen_address = Unix.(ADDR_INET (inet_addr_loopback, port)) in
  try
    let server =
      H2_lwt_unix.Server.create_connection_handler ?config:None
        ~request_handler:(fun _ reqd -> Server.handle_request grpc_routes reqd)
        ~error_handler:(fun _ ?request:_ _ _ ->
          print_endline "an error occurred")
    in
    let+ server =
      Lwt_io.establish_server_with_client_socket listen_address server
    in
    Logs.info (fun m -> m "Listening on port %i for grpc requests" port);
    server
  with
  | Unix.Unix_error (err, func, arg) ->
      (* Handle Unix system errors *)
      failwith
        (Printf.sprintf "Unix error: %s in function %s with argument %s"
           (Unix.error_message err) func arg)
  | exn ->
      (* Other error cases *)
      failwith (Printexc.to_string exn)

(* Function to create a connection to another server *)
let create_connection address port =
  (* Retrieve the address information for the server *)
  let* addresses =
    Lwt_unix.getaddrinfo address (string_of_int port)
      [ Unix.(AI_FAMILY PF_INET) ]
  in
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt socket Unix.SO_REUSEPORT true;

  let src_port =
    Common.start_bind_ports
    + (!num_servers * (!id - 1))
    + (port - Common.start_server_ports)
  in
  let bind_address = Unix.ADDR_INET (Unix.inet_addr_loopback, src_port) in
  (* Setup socket*)
  Lwt_unix.bind socket bind_address >>= fun () ->
  Lwt_unix.connect socket (List.hd addresses).Unix.ai_addr >>= fun () ->
  let error_handler _ = print_endline "error" in

  (* Launch *)
  let* connection =
    H2_lwt_unix.Client.create_connection ~error_handler socket
  in
  (* Store the connection in the global map *)
  Hashtbl.add server_connections port connection;

  Lwt.return ()

(* Function to establish connections to all other servers *)
let establish_connections () =
  (* Wait for a half a second for the other servers to spawn *)
  Lwt_unix.sleep Common.startup_wait >>= fun () ->
  let ports_to_connect =
    List.init !num_servers (fun i -> Common.start_server_ports + i)
    |> List.filter (fun p -> p <> !id - 1 + Common.start_server_ports)
  in
  Lwt_list.iter_s
    (fun port -> create_connection Common.hostname port)
    ports_to_connect

(* Main *)
let () =
  (* Argv *)
  id := int_of_string Sys.argv.(1);
  num_servers := int_of_string Sys.argv.(2);

  (* Setup *)
  Random.self_init ();
  Random.init ((Unix.time () |> int_of_float) + !id);
  let module Log = (val setup_logs ("raftserver" ^ Sys.argv.(1))) in
  (* Persistent storage loader, global side effect *)
  ignore (initialize_server_state !id);

  (* Launch three threads *)
  let main =
    let* server = start_server () in
    (* server that responds to RPC (listens on 9xxx)*)
    let* () = establish_connections () in
    setup_signal_handler
      (fun () ->
        let _ = Lwt_io.shutdown_server server in
        Log.info (fun m ->
            m "Received SIGTERM, shutting down, closing all sockets"))
      server_connections;
    follower_loop ()
  in

  Lwt_main.run main
