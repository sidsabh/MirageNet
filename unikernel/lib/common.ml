(* Common configuration *)
module Common = struct
  let hostname = "localhost"
  let max_connections = 31
  let start_bind_ports = 7001
  let start_server_ports = 9001
  let frontend_port = 8001
  let startup_wait = 0.5
  let log_level = Logs.Info
end
