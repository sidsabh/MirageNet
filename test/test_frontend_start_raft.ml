open Lwt.Infix
open Lwt.Syntax
open Grpc_lwt

let call_server address port =
  (* Setup Http/2 connection *)
  Lwt_unix.getaddrinfo address (string_of_int port) [ Unix.(AI_FAMILY PF_INET) ]
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
  let open Kvstore in
  let encode, decode = Service.make_client_functions Kvstore.FrontEnd.startRaft in
  let req = Kvstore.IntegerArg.make ~arg:3 () in 
  let enc = encode req |> Writer.contents in

  Client.call ~service:"kvstore.FrontEnd" ~rpc:"StartRaft"
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
           | None -> Kvstore.FrontEnd.StartRaft.Response.make ()))
    ()

let () =
  let open Lwt.Syntax in
  let port = 8001 in
  let address = "localhost" in
  Lwt_main.run
    (let+ res = call_server address port in
      match res with
      | Ok (res, _) -> 
          let error = res.error in
          if error == "" then
            print_endline "Raft servers started successfully"
          else
            print_endline error
      | Error _ -> print_endline "an error occurred")