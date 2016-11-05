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
            NewOpts = lists:keyreplace(scenario, 1, Opts, {scenario, Scenario}),
            spawn_link(fun() ->
                               setup(NumInstances, SleepTime, NewOpts)
                       end),
            case proplists:get_value(track_stats, NewOpts, false) of
                true ->
                    Self = self(),
                    Self ! stats,
                    stats_loop(0, 0, 0, 0, os:timestamp());
                false ->
                    receive
                        die -> erlang:halt(0)
                    end
            end
    end.

setup(0, _, _) -> ok;
setup(NumInstances, SleepTime, Opts) ->
    vmq_loadtest_instance_sup:start_instance(Opts),
    timer:sleep(SleepTime),
    setup(NumInstances - 1, SleepTime, Opts).

stats_loop(OldPm, OldCm, OldBi, OldBo, OldTS) ->
    receive
        die -> erlang:halt(0);
        stats ->
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
            io:format("~p~n", [Rates ++ Metrics ++ Stats]),

            erlang:send_after(1000, self(), stats),
            stats_loop(PM, CM, BI, BO, NewTS)
    end.


%%====================================================================
%% Internal functions
%%====================================================================
opt_specs() ->
    [
        {host,      $h, "host",      {string, "localhost"},     "MQTT Broker Host"},
        {port,      $p, "port",      {integer, 1883},           "MQTT Broker Port"},
        {scenario,  $s, "scenario",  string,                    "Scenario File"},
        {n,         $n, "num",       {integer, 10},             "Nr. of parallel instances"},
        {setup_rate,$r, "setup-rate",{integer, 10},             "Instance setup rate"},
        {src_ip,    undefined, "src-addr", string,      "Source IP used during connect"},
        {tls,       undefined, "tls", undefined,        "Enable TLS"},
        {client_cert, undefined, "cert", string,     "TLS Client Certificate"},
        {client_key, undefined, "key", string,     "TLS Client Private Key"},
        {client_ca, undefined, "cafile", string,     "TLS CA certificate chain"},
        {track_stats, undefined, "print-stats", undefined ,"Print Statistics"},
        {buffer, undefined, "buffer", {integer, undefined},      "The size of the user-level software buffer used by the driver"},
        {nodelay, undefined, "nodelay", {boolean, true}, "TCP_NODELAY is turned on for the socket"},
        {recbuf, undefined, "recbuf", {integer, undefined}, "The minimum size of the receive buffer to use for the socket"},
        {sndbuf, undefined, "sndbuf", {integer, undefined}, "The minimum size of the send buffer to use for the socket"}

    ].
