open Lwt.Infix
open Lwt.Syntax
open Grpc_lwt

let call_request_vote address port =
  (* Setup Http/2 connection for RequestVote RPC *)
  let* addresses =
    Lwt_unix.getaddrinfo address (string_of_int port)
      [ Unix.(AI_FAMILY PF_INET) ]
  in
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.connect socket (List.hd addresses).Unix.ai_addr >>= fun () ->
  let error_handler _ = print_endline "error" in
  let* connection =
    H2_lwt_unix.Client.create_connection ~error_handler socket
  in

  let open Ocaml_protoc_plugin in
  let open Raftkv in
  let encode, decode =
    Service.make_client_functions Raftkv.KeyValueStore.requestVote
  in
  let req =
    Raftkv.RequestVoteRequest.make ~candidate_id:1 ~term:2 ~last_log_index:3
      ~last_log_term:4 ()
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
                   failwith
                     (Printf.sprintf "Could not decode request: %s"
                        (Result.show_error e)))
           | None -> Raftkv.KeyValueStore.RequestVote.Response.make ()))
    ()

let () =
  let open Lwt.Syntax in
  let port = 9001 in
  let address = "localhost" in
  Lwt_main.run
    (let+ res = call_request_vote address port in
     match res with
     | Ok (res, _) ->
         let term = res.term in
         let voteGranted = res.vote_granted in
         Printf.printf
           "Received RequestVote response:\n\
            {\n\
            \t\"term\": %d\n\
            \t\"voteGranted\": %b\n\
            }\n"
           term voteGranted;
         flush stdout
     | Error _ -> print_endline "an error occurred")
