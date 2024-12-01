(* server.ml *)
open Grpc_lwt
open Raftkv
open Ocaml_protoc_plugin
open Lwt.Syntax
open Lwt.Infix
open Common

type append_entry_state = {
  mutable successful_replies : int;
  majority_condition : unit Lwt_condition.t;
}

(* Constants *)
let heartbeat_timeout = 0.1
let batch_timeout = 0.05

(* Config *)
let id = ref 0
let num_servers = ref 0

let server_connections : (int, H2_lwt_unix.Client.t) Hashtbl.t =
  Hashtbl.create 10

(* Persistent state on all servers *)
let term = ref 0
let voted_for = ref 0
let log : Raftkv.LogEntry.t list ref = ref []
let log_mutex = Lwt_mutex.create () (* Mutex to protect the log *)
let prev_log_index = ref (-1)

(* Volatile state on all servers *)
let commit_index = ref (-1)
let last_applied = ref (-1)
let role = ref "follower"
let leader_id = ref 0
let messages_recieved = ref false

(* Volatile state on leaders *)
let next_index = ref []
let next_index_mutex = Mutex.create () (* Mutex to protect the next_index *)
let match_index = ref []
let batch_condition = Lwt_condition.create ()
let last_batch = ref (-1)

(* Volatile state on candidates *)
let votes_received : int list ref = ref []
let votes_mutex = Lwt_mutex.create ()

(* Other*)
let state_map = Hashtbl.create 10

(* Handle GetState *)
let handle_get_state_request buffer =
  let decode, encode =
    Service.make_service_functions Raftkv.KeyValueStore.getState
  in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok _ ->
      Printf.printf "Received GetState request\n";
      flush stdout;
      let is_leader = !role = "leader" in
      let reply =
        Raftkv.KeyValueStore.GetState.Response.make ~term:!term
          ~isLeader:is_leader ()
      in
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e ->
      failwith
        (Printf.sprintf "Error decoding GetState request: %s"
           (Result.show_error e))

(* Handle Get *)
let handle_get_request buffer =
  let decode, encode =
    Service.make_service_functions Raftkv.KeyValueStore.get
  in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok v ->
      Printf.printf "Received Get request for key: %s\n" v.key;
      flush stdout;
      let value =
        try
          Hashtbl.find state_map v.key
          (* with Not_found -> failwith "Key not found" *)
        with Not_found -> "Key not found"
      in
      let reply =
        Raftkv.KeyValueStore.Get.Response.make ~wrongLeader:false ~error:""
          ~value ()
      in
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e ->
      failwith
        (Printf.sprintf "Error decoding Get request: %s" (Result.show_error e))

(* Handle Replace *)
let handle_replace_request buffer =
  let decode, encode =
    Service.make_service_functions Raftkv.KeyValueStore.replace
  in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok v ->
      Printf.printf "Received Replace request with key: %s and value: %s\n"
        v.key v.value;
      (* TODO: more to do here? *)
      let reply =
        Raftkv.KeyValueStore.Replace.Response.make ~wrongLeader:false ~error:""
          ()
      in
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e ->
      failwith
        (Printf.sprintf "Error decoding Replace request: %s"
           (Result.show_error e))

(* RAFT CORE *)

(* Handle RequestVoteRPC *)
let handle_request_vote buffer =
  let decode, encode =
    Service.make_service_functions Raftkv.KeyValueStore.requestVote
  in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok v ->
      let req_candidate_id = v.candidate_id in
      let req_term = v.term in
      let req_last_log_index = v.last_log_index in
      let req_last_log_term = v.last_log_term in

      Printf.printf
        "Received RequestVote request:\n\
         {\n\
         \t\"candidate_id\": %d\n\
         \t\"term\": %d\n\
         \t\"last_log_index\": %d\n\
         \t\"last_log_term\": %d\n\
         }\n"
        req_candidate_id req_term req_last_log_index req_last_log_term;
      flush stdout;

      let log_length = List.length !log in
      let last_log_term =
        if log_length = 0 then 0 else (List.nth !log (log_length - 1)).term
      in
      let log_is_up_to_date =
        req_last_log_term > last_log_term
        || req_last_log_term = last_log_term
           && req_last_log_index >= log_length - 1
      in

      (* Decide to vote or not *)
      let vote_granted, updated_term =
        if
          req_term < !term
          || (!voted_for <> 0 && !voted_for <> req_candidate_id)
          || not log_is_up_to_date
        then
          (* If the candidate's term is less than ours, we reject the vote *)
          (false, !term)
        else (
          (* If we haven't voted yet or have voted for this candidate and their log is up-to-date, we vote for them *)
          voted_for := req_candidate_id;
          (true, max req_term !term))
      in

      (* Create the response based on our decision *)
      let reply =
        Raftkv.KeyValueStore.RequestVote.Response.make ~vote_granted
          ~term:updated_term ()
      in
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e ->
      failwith
        (Printf.sprintf "Error decoding RequestVote request: %s"
           (Result.show_error e))

let apply_commited_entries () =
  let rec loop i =
    if i <= !commit_index then (
      let entry = List.nth !log i in
      Printf.printf "Applying log entry %d: %s\n" i entry.command;
      flush stdout;
      let key, value = Scanf.sscanf entry.command "%s %s" (fun k v -> (k, v)) in
      Hashtbl.replace state_map key value;
      last_applied := i;
      loop (i + 1))
  in
  loop (!last_applied + 1)

(* Handle AppendEntriesRPC *)
let handle_append_entries buffer =
  let log_entry_to_string (entry : Raftkv.LogEntry.t) =
    Printf.sprintf
      "\n\
       \t\t{\n\
       \t\t\t\"index\": %d\n\
       \t\t\t\"term\": %d\n\
       \t\t\t\"command\": \"%s\"\n\
       \t\t}"
      entry.index entry.term entry.command
  in
  let decode, encode =
    Service.make_service_functions Raftkv.KeyValueStore.appendEntries
  in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok v ->
      let req_term = v.term in
      let req_leader_id = v.leader_id in
      let req_prev_log_index = v.prev_log_index in
      let req_prev_log_term = v.prev_log_term in
      let req_entries = v.entries in
      let req_leader_commit = v.leader_commit in

      let return = ref false in
      let success = ref true in

      if req_leader_commit > !commit_index then
        Printf.printf
          "Received leader_commit_index: %d, current commit_index: %d\n"
          req_leader_commit !commit_index;
      flush stdout;

      if req_entries = [] then (
        if
          (* Leaders send periodic heartbeats (AppendEntries RPCs that carry no log entries) *)
          req_term > !term || (req_term = !term && req_leader_id <> !leader_id)
        then (
          (* TODO: confirm this if was incorrect*)
          if !role = "leader" then
            failwith "Multiple leaders in the same term, aborting";

          (* New leader *)
          term := req_term;
          leader_id := req_leader_id;
          role := "follower";
          messages_recieved := true;
          voted_for := 0;
          let _ =
            Lwt_mutex.with_lock votes_mutex (fun () ->
                votes_received := [];
                Lwt.return ())
          in
          Printf.printf "Leader %d recognized, term updated to %d\n"
            req_leader_id req_term;
          flush stdout)
        else if req_term = !term && req_leader_id = !leader_id then
          (* Heartbeat from established leader *)
          messages_recieved := true)
      else (
        Printf.printf
          "Received AppendEntries request:\n\
           {\n\
           \t\"term\": %d\n\
           \t\"leader_id\": %d\n\
           \t\"prev_log_index\": %d\n\
           \t\"prev_log_term\": %d\n\
           \t\"entries\": [%s\n\
           \t]\n\
           \t\"leader_commit\": %d\n\
           }\n"
          req_term req_leader_id req_prev_log_index req_prev_log_term
          (String.concat ", " (List.map log_entry_to_string req_entries))
          req_leader_commit;
        flush stdout);

      (* Condition 1: Reply false if term < currentTerm *)
      if req_term < !term then (
        if req_entries = [] then
          Printf.printf "Failing heartbeat, req_term: %d, term: %d\n" req_term
            !term;
        flush stdout;
        ignore (success := false);
        ignore (return := true));

      (* Condition 2: Reply false if log doesn't contain an entry at prevLogIndex whose term matches prevLogTerm *)
      if
        (not !return) && req_prev_log_index <> -1
        && (List.length !log <= req_prev_log_index
           || (List.nth !log req_prev_log_index).term <> req_prev_log_term)
      then (
        if req_entries = [] then
          Printf.printf
            "Failing heartbeat, prev_log_index: %d, log length: %d\n"
            req_prev_log_index (List.length !log);
        flush stdout;
        ignore (success := false);
        ignore (return := true));

      let truncate_log_if_conflict (log : Raftkv.LogEntry.t list)
          (entries : Raftkv.LogEntry.t list) (prev_log_index : int) :
          Raftkv.LogEntry.t list =
        (* Define the starting index *)
        let rec loop i =
          if
            i >= List.length log
            || i - prev_log_index - 1 >= List.length entries
          then (* If out of bounds, stop *)
            log
          else
            let log_term = (List.nth log i).term in
            let entry_term = (List.nth entries (i - prev_log_index - 1)).term in
            if log_term <> entry_term then
              (* If there is a conflict, truncate the log from index i *)
              List.filteri (fun idx _ -> idx < i) log
            else (* No conflict, continue to the next index *)
              loop (i + 1)
        in
        loop (prev_log_index + 1)
      in

      (* Condition 3: If an existing entry conflicts with a new one (same index but different terms), delete the existing entry and all that follow it *)
      (if not !return then
         (* Starting immediatly after prev_log_index, make sure log[i].term = entries[i-prev_log_index].term *)
         truncate_log_if_conflict !log req_entries req_prev_log_index
         |> fun new_log -> log := new_log);

      let rec drop n lst =
        if n <= 0 then lst
          (* No more elements to drop, return the remaining list *)
        else
          match lst with
          | [] -> [] (* If the list is empty, return an empty list *)
          | _ :: tail -> drop (n - 1) tail (* Drop one element and recurse *)
      in

      (* Condition 4: Append any new entries not already in the log *)
      (if not !return then
         let new_log_length = List.length !log in
         (* TODO: take the new entries from req_entries and append it to log *)
         if new_log_length < req_prev_log_index + List.length req_entries + 1
         then (
           let new_entries =
             drop (new_log_length - (req_prev_log_index + 1)) req_entries
           in
           log := List.concat [ !log; new_entries ];
           (* Printf.printf "New log after appending entries: %s\n" (String.concat ", " (List.map log_entry_to_string !log)); *)
           Printf.printf "New log length: %d\n" (List.length !log);
           flush stdout));

      (* Condition 5: If leaderCommit > commitIndex, set commitIndex = min(leaderCommit, index of last new entry) *)
      if not !return then
        if req_leader_commit > !commit_index then (
          let new_log_length = List.length !log in
          let new_commit_index = min req_leader_commit (new_log_length - 1) in
          commit_index := new_commit_index;
          apply_commited_entries ());

      (* Create the response based on our decision *)
      let reply =
        Raftkv.KeyValueStore.AppendEntries.Response.make ~term:!term
          ~success:!success ()
      in
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e ->
      failwith
        (Printf.sprintf "Error decoding AppendEntries request: %s"
           (Result.show_error e))

(* Call AppendEntriesRPC *)
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

  Client.call ~service:"raftkv.KeyValueStore" ~rpc:"AppendEntries"
    ~do_request:(H2_lwt_unix.Client.request connection ~error_handler:ignore)
    ~handler:
      (Client.Rpc.unary enc ~f:(fun decoder ->
           let+ decoder = decoder in
           match decoder with
           | Some decoder -> (
               Reader.create decoder |> decode |> function
               | Ok v -> v (* TODO: more to do here? *)
               | Error e ->
                   failwith
                     (Printf.sprintf "Could not decode request: %s"
                        (Result.show_error e)))
           | None -> Raftkv.KeyValueStore.AppendEntries.Response.make ()))
    ()

(* Runs concurrently *)
let rec send_entries follower_idx state new_commit_index =
  let prev_log_index = List.nth !next_index follower_idx - 1 in
  let verify_index (entry : Raftkv.LogEntry.t) =
    entry.index > prev_log_index && entry.index <= new_commit_index
  in
  let new_entries = List.filter verify_index !log in
  Lwt.async (fun () ->
      let port = 9001 + follower_idx in
      let* res = call_append_entries port prev_log_index new_entries in
      match res with
      | Ok (v, _) ->
          let _res_term = v.term in
          let res_success = v.success in
          (if res_success then (
             (* Fully updated nodes succeed*)
             state.successful_replies <- state.successful_replies + 1;
             Printf.printf
               "AppendEntries RPC to server %d successful, replies: %d\n"
               (follower_idx + 1) state.successful_replies;
             flush stdout;
             Mutex.lock next_index_mutex;
             next_index :=
               List.mapi
                 (fun i x ->
                   if i = follower_idx then new_commit_index + 1 else x)
                 !next_index;
             match_index :=
               List.mapi
                 (fun i x -> if i = follower_idx then new_commit_index else x)
                 !match_index;
             Mutex.unlock next_index_mutex;
             if state.successful_replies >= !num_servers / 2 then (
               (* A log entry is committed once the leader
                  that created the entry has replicated it on a majority of
                  the servers (e.g., entry 7 in Figure 6). This also commits
                  all preceding entries in the leader’s log, including entries
                  created by previous leaders. *)
               if new_commit_index > !commit_index then
                 commit_index := new_commit_index;
               Lwt_condition.signal state.majority_condition ()))
           else
             (* if term matches current term, decrease nextIndex[i] and try again *)
             let res_term = v.term in
             if res_term <> !term then (
               Printf.printf
                 "AppendEntries RPC to server %d failed, term mismatch\n"
                 (follower_idx + 1);
               flush stdout;
               term := res_term;
               role := "follower";
               voted_for := 0;
               votes_received := [])
             else (
               Mutex.lock next_index_mutex;
               next_index :=
                 List.mapi
                   (fun i x -> if i = follower_idx then x - 1 else x)
                   !next_index;
               Mutex.unlock next_index_mutex;
               Printf.printf
                 "AppendEntries RPC to server %d failed, trying again with \
                  nextIndex: %d\n"
                 (follower_idx + 1)
                 (List.nth !next_index follower_idx);
               flush stdout;
               send_entries follower_idx state new_commit_index));
          Lwt.return ()
      | Error _ -> Lwt.return ())

let rec batch_loop () =
  Lwt_unix.sleep batch_timeout >>= fun () ->
  let* () =
    if !role = "leader" then
      let* new_commit_index =
        Lwt_mutex.with_lock log_mutex (fun () ->
            Lwt.return (List.length !log - 1))
      in
      if !last_batch < new_commit_index then (
        Printf.printf "Batch loop detected %d new entries\n"
          (new_commit_index - !last_batch);
        flush stdout;

        (* Condition to wait for majority to commit *)
        let state =
          {
            successful_replies = 0;
            majority_condition = Lwt_condition.create ();
          }
        in

        (* Send out append entries *)
        let all_server_ids =
          List.init !num_servers (fun i -> i + 1)
          |> List.filter (fun server_id -> server_id <> !id)
        in
        List.iter
          (fun server_id ->
            let follower_idx = server_id - 1 in
            send_entries follower_idx state new_commit_index)
          all_server_ids;

        last_batch := new_commit_index;
        let* () = Lwt_condition.wait state.majority_condition in
        apply_commited_entries ();
        (* Majority condition reached, signal requests that they are ok to respond to client *)
        Lwt_condition.broadcast batch_condition ();
        Lwt.return_unit)
      else Lwt.return_unit
    else Lwt.return_unit
  in
  batch_loop ()

let append_entry key value =
  (* add entry to log *)
  let command = key ^ " " ^ value in
  Lwt_mutex.with_lock log_mutex (fun () ->
      let index = List.length !log in
      let new_log_entry = Raftkv.LogEntry.make ~term:!term ~command ~index () in
      log := List.concat [ !log; [ new_log_entry ] ];
      Lwt.return ())
  >>= fun () ->
  (* wait for batch condition for linearizability *)
  Lwt_condition.wait batch_condition >>= fun () -> Lwt.return ()

(* Handle Put *)
let handle_put_request buffer =
  let decode, encode =
    Service.make_service_functions Raftkv.KeyValueStore.put
  in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok v ->
      let req_key = v.key in
      let req_value = v.value in
      let req_client_id = v.clientId in
      let req_request_id = v.requestId in

      if !role <> "leader" then
        let correct_leader = string_of_int !leader_id in
        let reply =
          Raftkv.KeyValueStore.Put.Response.make ~wrongLeader:true ~error:""
            ~value:correct_leader ()
        in
        Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
      else (
        Printf.printf
          "Received Put request:\n\
           {\n\
           \t\"key\": \"%s\"\n\
           \t\"value\": \"%s\"\n\
           \t\"clientId\": %d\n\
           \t\"requestId\": %d\n\
           }\n"
          req_key req_value req_client_id req_request_id;
        flush stdout;
        let* _ = append_entry req_key req_value in
        let reply =
          Raftkv.KeyValueStore.Put.Response.make ~wrongLeader:false ~error:""
            ~value:"Success" ()
        in
        Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents)))
  | Error e ->
      failwith
        (Printf.sprintf "Error decoding Put request: %s" (Result.show_error e))

(* Call RequestVoteRPC *)
let call_request_vote port candidate_id term last_log_index last_log_term =
  let connection = Hashtbl.find server_connections port in

  (* Create and send the RequestVote RPC *)
  let encode, decode =
    Service.make_client_functions Raftkv.KeyValueStore.requestVote
  in
  let req =
    Raftkv.RequestVoteRequest.make ~candidate_id ~term ~last_log_index
      ~last_log_term ()
  in
  let enc = encode req |> Writer.contents in

  Client.call ~service:"raftkv.KeyValueStore" ~rpc:"RequestVote"
    ~do_request:(H2_lwt_unix.Client.request connection ~error_handler:ignore)
    ~handler:
      (Client.Rpc.unary enc ~f:(fun decoder ->
           let+ decoder = decoder in
           match decoder with
           | Some decoder -> (
               Reader.create decoder |> decode |> function
               | Ok v -> v
               | Error e ->
                   failwith (* TODO: Remove? *)
                     (Printf.sprintf "Could not decode request: %s"
                        (Result.show_error e)))
           | None -> Raftkv.KeyValueStore.RequestVote.Response.make ()))
    ()

let send_heartbeats () =
  let all_server_ids =
    List.init !num_servers (fun i -> i + 1)
    |> List.filter (fun server_id -> server_id <> !id)
  in
  Lwt_list.iter_p
    (fun server_id ->
      (* Don't request a vote from yourself *)
      let port = 9000 + server_id in
      (* Printf.printf "Leader: Sending heartbeat with prev_log_index: %d\n" !prev_log_index;
         flush stdout; *)
      let prev_log_index = List.nth !next_index (server_id - 1) - 1 in
      let* res = call_append_entries port prev_log_index [] in
      match res with
      | Ok (_, _) ->
          (* if not res.success then
             Printf.printf "Heartbeat to server %d returned false\n" server_id; *)
          Lwt.return ()
      | Error _ ->
          (* Printf.printf "Heartbeat to server %d failed\n" server_id; *)
          Lwt.return ())
    all_server_ids

(* Raftkv.FrontEnd.newLeader *)
(* TODO: Is this necessary? *)
let call_new_leader () =
  let* addresses =
    Lwt_unix.getaddrinfo "localhost" (string_of_int 8001)
      [ Unix.(AI_FAMILY PF_INET) ]
  in
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.connect socket (List.hd addresses).Unix.ai_addr >>= fun () ->
  let error_handler _ = print_endline "error" in
  let* connection =
    H2_lwt_unix.Client.create_connection ~error_handler socket
  in

  let encode, decode =
    Service.make_client_functions Raftkv.FrontEnd.newLeader
  in
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

let rec heartbeat_loop () =
  Lwt_unix.sleep heartbeat_timeout >>= fun () ->
  (* Send heartbeat to all servers *)
  send_heartbeats () >>= fun () ->
  if !role = "leader" then heartbeat_loop () else Lwt.return ()

(* This function handles the request vote and counting the votes *)
let count_votes num_votes_received =
  (* Check if we have enough votes for a majority *)
  let total_servers = !num_servers in
  let majority = (total_servers / 2) + 1 in
  if num_votes_received >= majority then (
    (* If we've received a majority, we win the election *)
    Printf.printf "We have a majority of votes (%d/%d).\n" num_votes_received
      total_servers;
    leader_id := !id;
    prev_log_index := List.length !log - 1;
    let _ =
      Lwt_mutex.with_lock log_mutex (fun () ->
          next_index := List.init !num_servers (fun _ -> List.length !log);
          Lwt.return ())
    in
    match_index := List.init !num_servers (fun _ -> -1);

    role := "leader";
    (* Tell frontend we are the new leader *)
    ignore (call_new_leader ());

    (* Send heartbeats for TODO: when does this stop?? *)
    Lwt.async (fun () -> heartbeat_loop ()))
  else
    (* Otherwise, we need to continue gathering votes *)
    Printf.printf "Votes received: %d, still need more votes.\n"
      num_votes_received

(* Function to request vote from other servers *)
let send_request_vote_rpcs () =
  let all_server_ids =
    List.init !num_servers (fun i -> i + 1)
    |> List.filter (fun server_id -> server_id <> !id)
  in
  Lwt_list.iter_p
    (fun server_id ->
      let port = 9000 + server_id in
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
      | Ok (res, _) ->
          let ret_term = res.term in
          let vote_granted = res.vote_granted in
          Printf.printf "Vote from raftserver%d: %b, term: %d\n" server_id
            vote_granted ret_term;
          flush stdout;
          let* num_votes_received =
            Lwt_mutex.with_lock votes_mutex (fun () ->
                if vote_granted && not (List.mem server_id !votes_received) then
                  votes_received := server_id :: !votes_received;
                Lwt.return (List.length !votes_received))
          in
          if !role = "candidate" then count_votes num_votes_received;
          Lwt.return_unit
      | Error _ ->
          Printf.printf "RequestVote RPC to server %d failed\n" server_id;
          Lwt.return ())
    all_server_ids

let rec election_loop () =
  (* Generate a random election timeout duration between 0.15s and 0.3s *)
  let timeout_duration = 0.15 +. Random.float (0.3 -. 0.15) in
  Lwt_unix.sleep timeout_duration >>= fun () ->
  (* Check if a message was received or if this node is already a leader *)
  if (not !messages_recieved) && !role <> "leader" then (
    Printf.printf "Election timeout reached; starting election...\n";
    flush stdout;

    (*  Begins an election to choose a new leader, self-vote first *)
    role := "candidate";
    term := !term + 1;
    voted_for := !id;
    votes_received := [ !id ];
    (* Restart the election timeout and send RequestVote RPCs *)
    Lwt.async (fun () -> send_request_vote_rpcs ());
    election_loop () (* Continue the loop *))
  else (
    (* Reset message received flag and restart the loop *)
    messages_recieved := false;
    election_loop ())

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

(* Function to create a connection to another server *)
let create_connection address port =
  (* Retrieve the address information for the server *)
  let* addresses =
    Lwt_unix.getaddrinfo address (string_of_int port)
      [ Unix.(AI_FAMILY PF_INET) ]
  in
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt socket Unix.SO_REUSEPORT true;

  let src_port = 7001 + (!num_servers * (!id - 1)) + (port - 9001) in
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
  (* Wait for a half a sec for the other servers to spawn *)
  Lwt_unix.sleep 0.5 >>= fun () ->
  let rec establish_for_ports ports =
    match ports with
    | [] -> Lwt.return ()
    | port :: rest ->
        create_connection "localhost" port >>= fun () ->
        establish_for_ports rest
  in

  let ports_to_connect =
    List.init !num_servers (fun i -> 9001 + i)
    |> List.filter (fun p -> p <> !id + 9000)
  in

  establish_for_ports ports_to_connect

let start_server () =
  let port = 9000 + !id in
  let listen_address = Unix.(ADDR_INET (inet_addr_loopback, port)) in
  let server_name = Printf.sprintf "raftserver%d" !id in
  try
    let server =
      H2_lwt_unix.Server.create_connection_handler ?config:None
        ~request_handler:(fun _ reqd -> Server.handle_request grpc_routes reqd)
        ~error_handler:(fun _ ?request:_ _ _ ->
          print_endline "an error occurred")
    in
    let+ _server =
      Lwt_io.establish_server_with_client_socket listen_address server
    in
    Printf.printf "Server %s listening on port %i for grpc requests\n"
      server_name port;
    flush stdout
  with
  | Unix.Unix_error (err, func, arg) ->
      (* Handle Unix system errors *)
      Printf.eprintf "Unix error: %s in function %s with argument %s\n"
        (Unix.error_message err) func arg;
      Lwt.return ()
  | exn ->
      (* Other error cases *)
      Printf.eprintf "Error: %s\n" (Printexc.to_string exn);
      Lwt.return ()

(* Main *)
let () =
  (* Argv *)
  id := int_of_string Sys.argv.(1);
  num_servers := int_of_string Sys.argv.(2);

  (* Setup *)
  Random.self_init ();
  Random.init ((Unix.time () |> int_of_float) + !id);
  setup_signal_handler server_connections;

  (* Launch three threads *)
  Lwt.async (fun () ->
      let* () = start_server () in
      (* server that responds to RPC (listens on 9xxx)*)
      let* () = establish_connections () in
      Lwt.join [ election_loop (); batch_loop () ]
      (* *)
      (* Concurrent *));

  (* while(1) *)
  let forever, _ = Lwt.wait () in
  Lwt_main.run forever
