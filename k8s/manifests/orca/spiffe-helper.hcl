agent_address = "/spirl-agent-socket/agent.sock"
cert_dir = "/tmp/orca-github-app"
daemon_mode = false
jwt_svids = [
  {
    jwt_audience = "sts.amazonaws.com"
    jwt_svid_file_name = "svid.jwt"
  }
]
