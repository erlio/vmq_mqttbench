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

-module(vmq_mqttbench).

%% API exports
-export([main/1]).

%%====================================================================
%% API functions
%%====================================================================

%% escript Entry point
main(Args) ->
    application:ensure_all_started(folsom),
    application:ensure_all_started(ssl),

    folsom_metrics:new_counter(published_msgs),
    folsom_metrics:new_counter(bytes_out),
    folsom_metrics:new_counter(consumed_msgs),
    folsom_metrics:new_counter(bytes_in),
    folsom_metrics:new_histogram(latency),
    folsom_metrics:new_counter(num_instances),
    folsom_metrics:tag_metric(published_msgs, vmq),
    folsom_metrics:tag_metric(bytes_out, vmq),
    folsom_metrics:tag_metric(consumed_msgs, vmq),
    folsom_metrics:tag_metric(bytes_in, vmq),
    folsom_metrics:tag_metric(num_instances, vmq),
    folsom_metrics:tag_metric(latency, vmq),


    vmq_loadtest_instance_sup:start_link(),
    case getopt:parse(opt_specs(), Args) of
        {ok, {Opts, _}} ->
            setup(Opts);
        {error, _} ->
            io:format("~p~n", [getopt:usage(opt_specs(), "vmq_mqttbench")])
    end,

    erlang:halt(0).

setup(Opts) ->
    NumInstances = proplists:get_value(n, Opts),
    case io_lib:fread("~d", os:cmd("ulimit -n")) of
        {error, E} ->
            io:format("Can't validate ulimit ~p~n", [E]),
            erlang:halt(0);
        {ok, [Ulimit], _} when Ulimit >= NumInstances ->
            ok;
        {ok, [Ulimit], _} ->
            io:format("Ulimit -n (~p) too small for configured number of instances~n", [Ulimit]),
            erlang:halt(0)
    end,

    SetupRate = proplists:get_value(setup_rate, Opts),
    SleepTime = 1000 div SetupRate,
    ScenarioFile = proplists:get_value(scenario, Opts),
    case file:consult(ScenarioFile) of
        {error, enoent} ->
            io:format("~p~n", [getopt:usage(opt_specs(), "vmq_mqttbench")]),
            erlang:halt(0);
        {error, Reason} ->
            io:format("Cant file:consult ~p due to ~p~n", [ScenarioFile, Reason]),
            erlang:halt(0);
        {ok, Scenario} ->
            NewOpts0 = lists:keyreplace(scenario, 1, Opts, {scenario, Scenario}),
            NewOpts1 =
            case proplists:get_value(src_ip, NewOpts0) of
                undefined -> NewOpts0;
                SrcIpStr ->
                    SrcIps0 =
                    lists:foldl(fun(StrIp, Acc) ->
                                         case inet:parse_address(StrIp) of
                                             {ok, SrcIp} -> [SrcIp|Acc];
                                             {error, _Reason} -> Acc
                                         end
                                end, [], re:split(SrcIpStr, ",", [{return, list}])),
                    SrcIps1 =
                    case SrcIps0 of
                        [] ->
                            %% maybe it is a prefix of an interface
                            {ok, Interfaces} = inet:getifaddrs(),
                            FilteredIfs =
                            lists:filter(fun({IfName, _}) ->
                                                 lists:prefix(SrcIpStr, IfName)
                                         end, Interfaces),
                            [proplists:get_value(addr, Conf) || {_, Conf} <- FilteredIfs];
                        _ ->
                            SrcIps0
                    end,
                    [{src_ips, SrcIps1}|NewOpts0]
            end,
            HostString = proplists:get_value(host, NewOpts1),
            HostsWithPortString = re:split(HostString, ",", [{return, list}]),
            HostsWithPort =
            lists:foldl(fun(HostWithPort, Acc) ->
                                case re:split(HostWithPort, ":", [{return, list}]) of
                                    [Host] -> [{Host, 1883}|Acc];
                                    [Host, Port] -> [{Host, list_to_integer(Port)}|Acc]
                                end
                        end, [], HostsWithPortString),
            NewOpts2 = [{hosts, HostsWithPort}|lists:keydelete(host, 1, NewOpts1)],
            Username = proplists:get_value(username, NewOpts2, undefined),
            NewOpts3 = [{username,Username}|lists:keydelete(username, 1, NewOpts2)],
            Password = proplists:get_value(password, NewOpts1, undefined),
            NewOpts4 = [{password,Password}|lists:keydelete(password, 1, NewOpts3)],
            Keepalive = proplists:get_value(keepalive, NewOpts1, 0),
            NewOpts5 = [{keepalive,Keepalive}|lists:keydelete(keepalive, 1, NewOpts4)],
            spawn_link(fun() ->
                               setup(NumInstances, SleepTime, NewOpts5)
                       end),
            case {proplists:get_value(stats_out, NewOpts5, false),
                  proplists:get_value(track_stats, NewOpts5, false)} of
                {StatsOut, TrackStats} when (StatsOut =/= false) or TrackStats ->
                    Self = self(),
                    Self ! stats,
                    MaybeFd = maybe_open_file(StatsOut),
                    write_csv_header(MaybeFd),
                    stats_loop(MaybeFd);
                {_, false} ->
                    receive
                        die -> erlang:halt(0)
                    end
            end
    end.

maybe_open_file(false) -> undefined;
maybe_open_file(FileName) ->
    {ok, FD} = file:open(FileName, [raw, write, binary]),
    FD.

setup(0, _, _) -> ok;
setup(NumInstances, SleepTime, Opts) ->
    vmq_loadtest_instance_sup:start_instance(Opts),
    timer:sleep(SleepTime),
    setup(NumInstances - 1, SleepTime, Opts).

stats_loop(Fd) ->
    stats_loop(Fd, {0,0,0,0,os:timestamp()}).
stats_loop(Fd, StatsTmp0) ->
    receive
        die -> erlang:halt(0);
        stats ->
            {Stats, StatsTmp1} = stats(StatsTmp0),
            io:format("~p~n", [Stats]),
            write_csv_line(Fd, Stats),

            erlang:send_after(1000, self(), stats),
            stats_loop(Fd, StatsTmp1)
    end.

stats({OldPm, OldCm, OldBi, OldBo, OldTS}) ->
    Metrics = folsom_metrics:get_metrics_value(vmq, counter),
    NewTS = os:timestamp(),
    {_, PM} = lists:keyfind(published_msgs, 1, Metrics),
    {_, CM} = lists:keyfind(consumed_msgs, 1, Metrics),
    {_, BI} = lists:keyfind(bytes_in, 1, Metrics),
    {_, BO} = lists:keyfind(bytes_out, 1, Metrics),
    TDiff = timer:now_diff(NewTS, OldTS),
    Rates =
    [{publish_rate, round(1000000 * (PM - OldPm) / TDiff)},
     {consume_rate, round(1000000 * (CM - OldCm) / TDiff)},
     {bytes_out_rate, round(1000000 * (BO - OldBo) / TDiff)},
     {bytes_in_rate, round(1000000 * (BI - OldBi) / TDiff)}
    ],
    [{latency, Lats}] = folsom_metrics:get_metrics_value(vmq, histogram),
    Stats = bear:get_statistics_subset(Lats, [n, min, max, arithmetic_mean,
                                              {percentile, [50, 75, 90, 95, 99, 999]}]),
    {Rates ++ Metrics ++ Stats, {PM, CM, BI, BO, NewTS}}.


fold_metrics(Transform, InitAcc, Stats) ->
    lists:foldl(
      fun
          ({percentile, Ps}, Acc) ->
              lists:foldl(fun(M, AccAcc) ->
                                  Transform(M, AccAcc)
                          end, Acc, Ps);
          (M, Acc) ->
              Transform(M, Acc)
      end, InitAcc, Stats).

write_csv_header(undefined) -> ok;
write_csv_header(Fd) ->
    {Stats, _} = stats({0, 0, 0, 0, os:timestamp()}),
    Header = fold_metrics(fun csv_header/2, ["\n"], Stats),
    file:write(Fd, ["timestamp,",Header]).

write_csv_line(undefined, _) -> ok;
write_csv_line(Fd, Stats) ->
    {A, B, _} = os:timestamp(),
    TS = integer_to_list((A * 1000000) + B),
    Line = fold_metrics(fun csv_line/2, ["\n"], Stats),
    file:write(Fd, [TS, ", ", Line]).

csv_header({Metric, _}, Acc) when is_integer(Metric) ->
    ["perc_" ++ integer_to_list(Metric), ","|Acc];
csv_header({Metric, _}, Acc) when is_atom(Metric) ->
    [atom_to_list(Metric), ","|Acc].

csv_line({_, V}, Acc) when is_float(V) ->
    [integer_to_list(round(V)), ","|Acc];
csv_line({_, V}, Acc) when is_integer(V) ->
    [integer_to_list(V), ","|Acc].


%%====================================================================
%% Internal functions
%%====================================================================
opt_specs() ->
    [
        {host,      $h, "host",      {string, "localhost:1883"},"MQTT broker host and port, multiple hosts can be specified divided by comma"},
        {scenario,  $s, "scenario",  string,                    "Scenario File"},
        {n,         $n, "num",       {integer, 10},             "Nr. of parallel instances"},
        {setup_rate,$r, "setup-rate",{integer, 10},             "Instance setup rate"},
        {src_ip,    undefined, "src-addr", string,      "Source IP used during connect, multiple IPs can be specified divided by comma. Alternatively an interface prefix can be provided and all locally configured IPs for the interface are used."},
        {tls,       undefined, "tls", undefined,        "Enable TLS"},
        {client_cert, undefined, "cert", string,     "TLS Client Certificate"},
        {client_key, undefined, "key", string,     "TLS Client Private Key"},
        {client_ca, undefined, "cafile", string,     "TLS CA certificate chain"},
        {track_stats, undefined, "print-stats", undefined ,"Print Statistics"},
        {stats_out, undefined, "out", string, "Print Statistics to File"},
        {buffer, undefined, "buffer", {integer, undefined},      "The size of the user-level software buffer used by the driver"},
        {nodelay, undefined, "nodelay", {boolean, true}, "TCP_NODELAY is turned on for the socket"},
        {recbuf, undefined, "recbuf", {integer, undefined}, "The minimum size of the receive buffer to use for the socket"},
        {sndbuf, undefined, "sndbuf", {integer, undefined}, "The minimum size of the send buffer to use for the socket"},
        {username, undefined, "username", string, "The MQTT username"},
        {password, undefined, "password", string, "The MQTT password"},
        {keepalive, undefined, "keepalive", {integer, 0}, "The MQTT keepalive value"}
    ].
