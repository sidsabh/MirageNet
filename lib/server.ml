(* server.ml *)
open Grpc_lwt
open Kvstore

(* Global Vars *)
let num_servers = ref 0
let role = ref "follower"




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
      Printf.printf "Received RequestVote request:\n{\n\t\"candidate_id\": %d\n\t\"term\": %d\n\t\"last_log_index\": %d\n\t\"last_log_term\": %d\n}\n" v.candidate_id v.term v.last_log_index v.last_log_term;
      flush stdout;
      let reply = KeyValueStore.RequestVote.Response.make ~vote_granted:false ~term:0 () in
      Lwt.return (Grpc.Status.(v OK), Some (encode reply |> Writer.contents))
  | Error e -> failwith (Printf.sprintf "Error decoding RequestVote request: %s" (Result.show_error e))

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


(* Election timeout function that checks follower status and initiates election if needed *)
let election_timeout () =
  let open Lwt.Syntax in
  let timeout_duration = 0.15 +. (Random.float (0.3 -. 0.15)) in(* Random float between 0.15 and 0.3 *)
  Printf.printf "Election timeout set to %f seconds\n" timeout_duration;
  flush stdout;
  let* () = Lwt_unix.sleep timeout_duration in
  if !role = "follower" then (
    print_endline "Election timeout reached, starting election...";
    (* send_request_vote_rpc ();  Placeholder for your election start logic *)
  );
  Lwt.return()

let () =
  let open Lwt.Syntax in
  let id = Sys.argv.(1) |> int_of_string in
  num_servers := Sys.argv.(2) |> int_of_string;

  (* Seed the random number generator differently for each instance *)
  Random.self_init ();
  Random.init ((Unix.time () |> int_of_float) + id);

  let port = 9000 + id in
  let listen_address = Unix.(ADDR_INET (inet_addr_loopback, port)) in
  let server_name = Printf.sprintf "raftserver%d" id in

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

  (* Initialize as follower and start election timeout asynchronously *)
  role := "follower";
  Lwt.async election_timeout;

  (* Keep the server running *)
  let forever, _ = Lwt.wait () in
  Lwt_main.run forever;