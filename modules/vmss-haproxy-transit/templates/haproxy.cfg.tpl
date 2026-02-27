global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 4096
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 10s
    timeout client  60s
    timeout server  60s
    retries 3

frontend kafka_in
    bind *:${kafka_port}
    default_backend kafka_out

backend kafka_out
    server confluent ${confluent_pe_ip}:${kafka_port} check inter 10s fall 3 rise 2
