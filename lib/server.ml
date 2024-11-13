(* server.ml *)
open Grpc_lwt
open Kvstore
open Lwt.Syntax
open Lwt.Infix

(* Global Vars *)
let id = ref 0
let num_servers = ref 0
let role = ref "follower"
let prev_role = ref "follower"
let term = ref 0
let voted_for = ref 0
let votes_received : int list ref = ref []
let last_log_index = ref 0
let last_log_term = ref 0





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

(* RAFT CORE *)

(* Handle RequestVoteRPC *)
let handle_request_vote buffer =
  let open Ocaml_protoc_plugin in
  let open Kvstore in
  let decode, encode = Service.make_service_functions KeyValueStore.requestVote in
  let request = Reader.create buffer |> decode in
  match request with
  | Ok v ->
      let req_candidate_id = v.candidate_id in
      let req_term = v.term in
      let req_last_log_index = v.last_log_index in
      let req_last_log_term = v.last_log_term in

      Printf.printf "Received RequestVote request:\n{\n\t\"candidate_id\": %d\n\t\"term\": %d\n\t\"last_log_index\": %d\n\t\"last_log_term\": %d\n}\n"
        req_candidate_id req_term req_last_log_index req_last_log_term;
      flush stdout;
      
      let log_is_up_to_date = 
        (req_last_log_term > !last_log_term) || 
        (req_last_log_term = !last_log_term && req_last_log_index >= !last_log_index)
      in

      (* Decide to vote or not *)
      let vote_granted, updated_term =
        if req_term < !term || (!voted_for <> 0 && !voted_for <> req_candidate_id) || not log_is_up_to_date then 
          (* If the candidate's term is less than ours, we reject the vote *)
          false, !term
        else (
          (* If we haven't voted yet or have voted for this candidate and their log is up-to-date, we vote for them *)
          voted_for := req_candidate_id;
          true, max req_term !term
        )
      in

      (* Create the response based on our decision *)
      let reply = KeyValueStore.RequestVote.Response.make ~vote_granted ~term:updated_term () in
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))

  | Error e -> 
      failwith (Printf.sprintf "Error decoding RequestVote request: %s" (Result.show_error e))

let key_value_store_service =
  Server.Service.(
    v ()
    |> add_rpc ~name:"GetState" ~rpc:(Unary handle_get_state_request)
    |> add_rpc ~name:"Get" ~rpc:(Unary handle_get_request)
    |> add_rpc ~name:"Put" ~rpc:(Unary handle_put_request)
    |> add_rpc ~name:"Replace" ~rpc:(Unary handle_replace_request)
    |> add_rpc ~name:"RequestVote" ~rpc:(Unary handle_request_vote)
    |> handle_request)

let server =
  Server.(
    v ()
    |> add_service ~name:"kvstore.KeyValueStore" ~service:key_value_store_service)


(* Condition variable to signal the election loop when timeout occurs *)
let election_timeout_condition = Lwt_condition.create ()

(* Function to spawn and manage the election timeout *)
let start_election_timeout () =
  let timeout_duration = 0.15 +. (Random.float (0.3 -. 0.15)) in
  Printf.printf "Election timeout set to %f seconds\n" timeout_duration;
  flush stdout;
  (* Wait for the timeout duration and then signal the condition variable *)
  let+ () = Lwt_unix.sleep timeout_duration in
  Lwt_condition.signal election_timeout_condition ()

let call_request_vote address port candidate_id term last_log_index last_log_term =
  
  (* Setup Http/2 connection for RequestVote RPC *)
  Lwt_unix.getaddrinfo address (string_of_int port) [ Unix.(AI_FAMILY PF_INET) ]
  >>= fun addresses ->
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.connect socket (List.hd addresses).Unix.ai_addr
  >>= fun () ->

  let error_handler _ = print_endline "RPC Error"; in
  H2_lwt_unix.Client.create_connection ~error_handler socket
  >>= fun connection ->

  (* Create and send the RequestVote RPC *)
  let open Ocaml_protoc_plugin in
  let encode, decode = Service.make_client_functions Kvstore.KeyValueStore.requestVote in
  let req = Kvstore.RequestVoteRequest.make ~candidate_id ~term ~last_log_index ~last_log_term () in
  let enc = encode req |> Writer.contents in

  Client.call ~service:"kvstore.KeyValueStore" ~rpc:"RequestVote"
    ~do_request:(H2_lwt_unix.Client.request connection ~error_handler:ignore)
    ~handler:
      (Client.Rpc.unary enc ~f:(fun decoder ->
            let+ decoder = decoder in
            match decoder with
            | Some decoder -> (
                Reader.create decoder |> decode |> function
                | Ok v -> v
                | Error e -> failwith (Printf.sprintf "Could not decode request: %s" (Result.show_error e)))
            | None -> Kvstore.KeyValueStore.RequestVote.Response.make ()))
    ()
  
  
(* This function handles the request vote and counting the votes *)
let count_votes () =
  (* Check if we have enough votes for a majority *)
  let total_servers = !num_servers in
  let majority = total_servers / 2 + 1 in
  if List.length !votes_received >= majority then
    (* If we've received a majority, we win the election *)
    Printf.printf "We have a majority of votes (%d/%d).\n" (List.length !votes_received) total_servers
  else
    (* Otherwise, we need to continue gathering votes *)
    Printf.printf "Votes received: %d, still need more votes.\n" (List.length !votes_received)

(* Function to request vote from other servers *)
let send_request_vote_rpcs () =
  let all_server_ids = List.init !num_servers (fun i -> i + 1) in
  List.iter (fun server_id ->
    if server_id <> !id then (* Don't request a vote from yourself *)
      Lwt.async (fun () ->
        let address = "localhost" in
        let port = 9000 + server_id in
        let candidate_id = !id in
        let term = !term in
        let last_log_index = !last_log_index in
        let last_log_term = !last_log_term in
        call_request_vote address port candidate_id term last_log_index last_log_term >>= fun res ->
        match res with
        | Ok (res, _) -> 
            Printf.printf "RequestVote RPC to server %d successful\n" server_id;
            let ret_term = res.term in
            let vote_granted = res.vote_granted in
            Printf.printf "Vote from raftserver%d: %b, term: %d\n" server_id vote_granted ret_term;
            if vote_granted && not (List.mem server_id !votes_received) then begin
              votes_received := server_id :: !votes_received;
              count_votes ();
            end;
            Lwt.return ()  (* Properly return unit Lwt.t *)
        | Error _ -> 
            Printf.printf "RequestVote RPC to server %d failed\n" server_id;
            Lwt.return ()  (* Return unit Lwt.t *)
      )
  ) all_server_ids;
  Lwt.return()




(* Main election loop using a while true structure *)
let election_loop () =
  
  (* Start the initial election timeout before entering the loop *)
  let _ = start_election_timeout () in

  (* Main election loop *)
  let loop () =
    (* Wait for the election timeout to complete *)
    let* () = Lwt_condition.wait election_timeout_condition in

    (* Start the election process here after timeout *)
    Printf.printf "Election timeout reached; starting election...\n";
    flush stdout;

    (* Update necessary variables for the election *)
    role := "candidate";
    term := !term + 1;
    voted_for := !id;
    votes_received := [!id];

    (* Restart the election timeout *)
    let _ = start_election_timeout () in

    (* Send RequestVote RPCs to other servers asynchronously *)
    Lwt.async (fun () -> send_request_vote_rpcs ());
    Lwt.return()
    (* Continue the loop *)
    (* loop () *)
  in
  loop ()
 



let () =
  id := int_of_string Sys.argv.(1);
  num_servers := int_of_string Sys.argv.(2);

  (* Seed the random number generator *)
  Random.self_init ();
  Random.init ((Unix.time () |> int_of_float) + !id);

  let port = 9000 + !id in
  let listen_address = Unix.(ADDR_INET (inet_addr_loopback, port)) in
  let server_name = Printf.sprintf "raftserver%d" !id in

  (* Start the server *)
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
    flush stdout);

  (* Initialize as follower *)
  role := "follower";
  prev_role := "follower";

  (* Start election timeout *)
  Lwt.async election_loop;

  (* Keep the server running *)
  let forever, _ = Lwt.wait () in
  Lwt_main.run forever;
