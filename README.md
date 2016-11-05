# vmq_mqttbench

## build it

    make

## write the scenario file

```erlang
{setup, [
    {subscribe, "hello/world/%c", 0},
    {tick, 30000}
]}.
{steps, [
    {publish, "hello/world/%c", 0, 100},
    {tick, 1000}

]}.
```

the `setup` part is executed during setup phase, the `steps` phase is what is
running for every tick. Make sure to have a `{tick, Milliseconds}` as the last
step of `setup` as this indicates when an instance moves over from setup to
benchmark phase. Once in the benchmark phase the `{tick, Milliseconds}` control
the frequency the steps are executed. In the example above a single instance
publishes a 100 byte message to topic `hello/world/<client-id` using QoS 0. Note
the `%c` is substituted with a randomly generated client id.

## run the benchmark

    ./vmq_mqttbench -s sample.steps -p 1889 -h localhost --print-stats -n 10000 -r 100

### ask for help 

    ./vmq_mqttbench -h
    Usage: vmq_mqttbench [-h [<host>]] [-p [<port>]] [-s <scenario>]
                         [-n [<n>]] [-r [<setup_rate>]] [--src-addr <src_ip>]
                         [--tls] [--cert <client_cert>] [--key <client_key>]
                         [--cafile <client_ca>] [--print-stats]
                         [--buffer [<buffer>]] [--nodelay [<nodelay>]]
                         [--recbuf [<recbuf>]] [--sndbuf [<sndbuf>]]
    
      -h, --host        MQTT Broker Host [default: localhost]
      -p, --port        MQTT Broker Port [default: 1883]
      -s, --scenario    Scenario File
      -n, --num         Nr. of parallel instances [default: 10]
      -r, --setup-rate  Instance setup rate [default: 10]
      --src-addr        Source IP used during connect
      --tls             Enable TLS
      --cert            TLS Client Certificate
      --key             TLS Client Private Key
      --cafile          TLS CA certificate chain
      --print-stats     Print Statistics
      --buffer          The size of the user-level software buffer used by the 
                        driver [default: undefined]
      --nodelay         TCP_NODELAY is turned on for the socket [default: true]
      --recbuf          The minimum size of the receive buffer to use for the 
                        socket [default: undefined]
      --sndbuf          The minimum size of the send buffer to use for the 
                        socket [default: undefined]
        
