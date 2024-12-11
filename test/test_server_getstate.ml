open Lwt.Infix
open Lwt.Syntax
open Grpc_lwt

let call_get_state address port =
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
  let encode, decode = Service.make_client_functions Raftkv.KeyValueStore.getState in
  let req = () in
  let enc = encode req |> Writer.contents in

  Client.call ~service:"raftkv.KeyValueStore" ~rpc:"GetState"
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
           | None -> Raftkv.State.make ~term:0 ~isLeader:false ()))
    ()

let () =
  let open Lwt.Syntax in
  let port = 8080 in
  let address = "192.168.122.2" in
  Lwt_main.run
    (let+ res = call_get_state address port in
     match res with
     | Ok (res, _) ->
         let term = res.term in
         let is_leader = res.isLeader in
         Printf.printf
           "Received GetState response:\n\
            {\n\
            \t\"term\": %d\n\
            \t\"isLeader\": %b\n\
            }"
           term is_leader
     | Error _ -> print_endline "An error occurred")