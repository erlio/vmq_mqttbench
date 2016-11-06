%% Copyright 2016 Erlio GmbH Basel Switzerland (http://erl.io)
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(vmq_loadtest_instance).
-include_lib("vmq_commons/include/vmq_types.hrl").
-export([start_link/1,
         init/2]).

start_link(Opts) ->
    proc_lib:start_link(?MODULE, init, [self(), Opts]).

init(Parent, Opts) ->
    random:seed(os:timestamp()),
    ok = proc_lib:init_ack(Parent, {ok, self()}),
    try
        put(track_stats, proplists:get_value(track_stats, Opts, true)),
        connect(Opts)
    catch
        E:R ->
            io:format("[~p] instance terminated due to ~p ~p~n", [self(), E, R])
    end,
    metrics({num_instances, {dec, 1}}).

connect_opts(Opts) ->
    Buffers = lists:foldl(fun({buffer, S} = B, Acc) when is_integer(S) ->
                                  [B|Acc];
                             ({sndbuf, S} = B, Acc) when is_integer(S) ->
                                  [B|Acc];
                             ({recbuf, S} = B, Acc) when is_integer(S) ->
                                  [B|Acc];
                             (_, Acc) ->
                                  Acc
                          end, [], Opts),
    ConnectOpts1 = [binary, {reuseaddr, true}, {active, false}, {packet, raw},
                    {nodelay, proplists:get_value(nodelay, Opts, false)}
                   |Buffers],
    case proplists:get_value(src_ips, Opts) of
        undefined -> ConnectOpts1;
        SrcIps ->
            SrcIp = lists:nth(random:uniform(length(SrcIps)), SrcIps),
            [{ip, SrcIp}|ConnectOpts1]
    end.

connect(Opts) ->
    connect(proplists:get_bool(tls, Opts), Opts).
connect(false, Opts) ->
    connect(gen_tcp, connect_opts(Opts), Opts);
connect(true, Opts) ->
    ConnectOpts = [{certfile, proplists:get_value(client_cert, Opts)},
                   {keyfile, proplists:get_value(client_key, Opts)},
                   {cacertfile, proplists:get_value(client_ca, Opts)}
                  | connect_opts(Opts)],
    connect(ssl, ConnectOpts, Opts).

connect(Transport, ConnectOpts, Opts) ->
    Hosts = proplists:get_value(hosts, Opts),
    {Host, Port} = lists:nth(random:uniform(length(Hosts)), Hosts),
    case Transport:connect(Host, Port, ConnectOpts) of
        {ok, Socket} ->
            setup(Transport, Socket, Opts);
        {error, Reason} ->
            exit({cant_connect, Reason})
    end.

send(Transport, Socket, Data, What) ->
    case Transport:send(Socket, Data) of
        ok ->
            metrics({bytes_out, {inc, iolist_size(Data)}}),
            ok;
        {error, Reason} ->
            exit({cant_send, What, Reason})
    end.

setup(Transport, Socket, Opts) ->
    ClientId = gen_client_id(),
    Connect = vmq_parser:gen_connect(ClientId, Opts),
    send(Transport, Socket, Connect, connect),
    {Proto, ProtoClosed, ProtoError} = active_once(Transport, Socket),
    receive
        {Proto, Socket, Data} ->
            case vmq_parser:parse(Data) of
                {#mqtt_connack{}, Rest} ->
                    metrics({num_instances, {inc, 1}}),
                    Scenario = proplists:get_value(scenario, Opts, []),
                    EScenario = enrich_scenario(Scenario, ClientId),
                    SetupSteps = proplists:get_value(setup, EScenario, []),
                    run_steps(Transport, Socket, SetupSteps),
                    loop(Transport, Socket, Rest, EScenario);
                Other ->
                    exit({unexpected_msg_in_setup, Other})
            end;
        {ProtoClosed, Socket} ->
            exit(socket_closed_in_setup);
        {ProtoError, Socket, Reason} ->
            exit({socket_error_in_setup, Reason})
    end.

run_steps(_Transport, _Socket, []) -> ok;
run_steps(Transport, Socket, [{tick, Millis}|Steps]) ->
    erlang:send_after(Millis, self(), tick),
    run_steps(Transport, Socket, Steps);
run_steps(Transport, Socket, [{subscribe, Topic, QoS}|Steps]) ->
    Mid = gen_mid(),
    Subscribe = vmq_parser:gen_subscribe(Mid, Topic, QoS),
    send(Transport, Socket, Subscribe, subscribe),
    run_steps(Transport, Socket, Steps);
run_steps(Transport, Socket, [{publish, Topic, QoS, PayloadSize}|Steps]) ->
    Payload = term_to_binary([os:timestamp(), crypto:rand_bytes(PayloadSize)]),
    Publish = vmq_parser:gen_publish(Topic, QoS, Payload, [{mid, gen_mid()}]),
    send(Transport, Socket, Publish, publish),
    case QoS of
        0 ->
            metrics({published_msgs, {inc, 1}});
        _ -> ignore
    end,
    run_steps(Transport, Socket, Steps);
run_steps(_, _, [Step|_]) ->
    exit({step_error, Step}).

enrich_scenario(Scenario, ClientId) ->
    SetupSteps = proplists:get_value(setup, Scenario, []),
    ESetupSteps = enrich_steps(SetupSteps, ClientId, []),
    Steps = proplists:get_value(steps, Scenario, []),
    ESteps = enrich_steps(Steps, ClientId, []),
    [{setup, ESetupSteps},
     {steps, ESteps}].


enrich_steps([{subscribe, Topic, QoS}|Steps], ClientId, Acc) ->
    ETopic = re:replace(Topic, "%c", ClientId, [{return, list}, global]),
    EStep = {subscribe, ETopic, QoS},
    enrich_steps(Steps, ClientId, [EStep|Acc]);
enrich_steps([{publish, Topic, QoS, PayloadSize}|Steps], ClientId, Acc) ->
    ETopic = re:replace(Topic, "%c", ClientId, [{return, list}, global]),
    EStep = {publish, ETopic, QoS, PayloadSize},
    enrich_steps(Steps, ClientId, [EStep|Acc]);
enrich_steps([Step|Steps], ClientId, Acc) ->
    enrich_steps(Steps, ClientId, [Step|Acc]);
enrich_steps([], _, Acc) -> lists:reverse(Acc).




loop(Transport, Socket, Buf, Scenario) ->
    loop(Transport, Socket, Buf, false, proplists:get_value(steps, Scenario, [])).

loop(Transport, Socket, Buf, IsActive, Steps) ->
    {Proto, ProtoError, ProtoClosed} = active_once(IsActive, Transport, Socket),
    receive
        tick ->
            run_steps(Transport, Socket, Steps),
            loop(Transport, Socket, Buf, IsActive, Steps);
        {Proto, _, Data} ->
            metrics({bytes_in, {inc, byte_size(Data)}}),
            NewBuf = <<Buf/binary, Data/binary>>,
            case vmq_parser:parse(NewBuf) of
                more ->
                    loop(Transport, Socket, NewBuf, false, Steps);
                {error, Reason} ->
                    exit({parse_error, Reason});
                {Frame, Rest} ->
                    handle_frame(Transport, Socket, Frame),
                    loop(Transport, Socket, Rest, false, Steps)
            end;
        {ProtoError, _, Reason} ->
            exit({socket_error, Reason});
        {ProtoClosed, _} ->
            exit(socket_close)
    end.

handle_frame(_Transport, _Socket, #mqtt_suback{}) -> ok;
handle_frame(_Transport, _Socket, #mqtt_puback{}) ->
    metrics({published_msgs, {inc, 1}}),
    ok;
handle_frame(_Transport, _Socket, #mqtt_publish{qos=0, payload=Payload}) ->
    latency(Payload),
    metrics({consumed_msgs, {inc, 1}}),
    ok;
handle_frame(Transport, Socket, #mqtt_publish{qos=1, message_id=MId, payload=Payload}) ->
    latency(Payload),
    metrics({consumed_msgs, {inc, 1}}),
    send(Transport, Socket, vmq_parser:gen_puback(MId), puback);
handle_frame(Transport, Socket, #mqtt_publish{qos=2, message_id=MId, payload=Payload}) ->
    put({qos2, MId}, Payload),
    send(Transport, Socket, vmq_parser:gen_pubrec(MId), pubrec);
handle_frame(Transport, Socket, #mqtt_pubrec{message_id=MId}) ->
    send(Transport, Socket, vmq_parser:gen_pubrel(MId), pubrel);
handle_frame(Transport, Socket, #mqtt_pubrel{message_id=MId}) ->
    K = {qos1, MId},
    latency(get(K)),
    erase(K),
    metrics({consumed_msgs, {inc, 1}}),
    send(Transport, Socket, vmq_parser:gen_pubcomp(MId), pubcomp);
handle_frame(_Transport, _Socket, #mqtt_pubcomp{}) ->
    metrics({published_msgs, {inc, 1}}),
    ok;
handle_frame(_, _, Frame) ->
    exit({unexpected_frame, element(1, Frame)}).

active_once(Transport, Socket) ->
    active_once(false, Transport, Socket).

active_once(true, gen_tcp, _) -> {tcp, tcp_error, tcp_closed};
active_once(true, ssl, _) -> {ssl, ssl_error, ssl_closed};
active_once(false, gen_tcp, Socket) ->
    ok = inet:setopts(Socket, [{active, once}]),
    {tcp, tcp_error, tcp_closed};
active_once(false, ssl, Socket) ->
    ok = ssl:setopts(Socket, [{active, once}]),
    {ssl, ssl_error, ssl_closed}.

gen_mid() ->
    case get(mid) of
        OldMid when OldMid < 65535 ->
            put(mid, OldMid + 1),
            OldMid;
        _ ->
            put(mid, 0),
            gen_mid()
    end.

gen_client_id() ->
    list_to_binary("vmq-" ++
    integer_to_list(erlang:phash2(node())) ++ "." ++
    integer_to_list(erlang:phash2(self())) ++ "." ++
    integer_to_list(erlang:phash2(os:timestamp()))).

metrics(Metric) ->
    case get(track_stats) of
        true ->
            folsom_metrics:notify(Metric);
        _ -> ignore
    end.

latency(undefined) -> ignore;
latency(Payload) ->
    case get(track_stats) of
        true ->
            TS1 = os:timestamp(),
            [TS0, _] = binary_to_term(Payload),
            Diff = timer:now_diff(TS1, TS0),
            folsom_metrics:notify({latency, Diff});
        _ -> ignore
    end.
