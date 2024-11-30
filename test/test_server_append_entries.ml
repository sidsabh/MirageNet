open Lwt.Infix
open Lwt.Syntax
open Grpc_lwt

let call_append_entries address port =
  (* Setup Http/2 connection for RequestVote RPC *)
  Lwt_unix.getaddrinfo address (string_of_int port) [ Unix.(AI_FAMILY PF_INET) ]
  >>= fun addresses ->
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.connect socket (List.hd addresses).Unix.ai_addr >>= fun () ->
  let error_handler _ = print_endline "error" in
  H2_lwt_unix.Client.create_connection ~error_handler socket
  >>= fun connection ->
  (* code generation for RequestVote RPC *)
  let open Ocaml_protoc_plugin in
  let open Raftkv in
  let encode, decode =
    Service.make_client_functions Raftkv.KeyValueStore.appendEntries
  in
  let entries =
    [
      Raftkv.LogEntry.make ~term:1 ~command:"command1" ();
      Raftkv.LogEntry.make ~term:1 ~command:"command2" ();
    ]
  in
  let req =
    Raftkv.AppendEntriesRequest.make ~term:1 ~leader_id:2 ~prev_log_index:3
      ~prev_log_term:4 ~entries ~leader_commit:6 ()
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
               | Ok v -> v
               | Error e ->
                   failwith
                     (Printf.sprintf "Could not decode request: %s"
                        (Result.show_error e)))
           | None -> Raftkv.KeyValueStore.AppendEntries.Response.make ()))
    ()

let () =
  let open Lwt.Syntax in
  let port = 9001 in
  let address = "localhost" in
  Lwt_main.run
    (let+ res = call_append_entries address port in
     match res with
     | Ok (res, _) ->
         (* Handle successful response and print details *)
         let res_term = res.term in
         let res_success = res.success in
         Printf.printf
           "Received AppendEntries response:\n\
            {\n\
            \t\"term\": %d\n\
            \t\"success\": %b\n\
            }\n"
           res_term res_success;
         flush stdout
     | Error _ ->
         (* Handle failure *)
         Printf.printf "AppendEntries RPC failed\n";
         flush stdout)
