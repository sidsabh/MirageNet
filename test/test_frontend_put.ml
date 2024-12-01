open Lwt.Infix
open Lwt.Syntax
open Grpc_lwt

let call_put address port =
  (* Setup Http/2 connection *)
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
  let encode, decode = Service.make_client_functions Raftkv.FrontEnd.put in
  let req =
    Raftkv.KeyValue.make ~key:"1" ~value:"test_command" ~clientId:1 ~requestId:2
      ()
  in
  let enc = encode req |> Writer.contents in

  Client.call ~service:"raftkv.FrontEnd" ~rpc:"Put"
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
           | None -> Raftkv.FrontEnd.Put.Response.make ()))
    ()

let () =
  let open Lwt.Syntax in
  let port = 8001 in
  let address = "localhost" in
  Lwt_main.run
    (let+ res = call_put address port in
     match res with
     | Ok (res, _) ->
         let value = res.value in
         print_endline value
     | Error _ -> print_endline "an error occurred")
