-module(ameo_vnode).
-behaviour(riak_core_vnode).

-export([start_vnode/1,
         init/1,
         terminate/2,
         handle_command/3,
         is_empty/1,
         delete/1,
         handle_handoff_command/3,
         handoff_starting/2,
         handoff_cancelled/1,
         handoff_finished/2,
         handle_handoff_data/2,
         encode_handoff_item/2,
         handle_overload_command/3,
         handle_overload_info/2,
         handle_coverage/4,
         handle_exit/3]).

-export([handle_info/2]).
-include_lib("kernel/include/logger.hrl").
-ignore_xref([
             start_vnode/1
             ]).

-record(state, {partition, table_id, table_name, topic_table}).

%% API
start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

init([Partition]) ->
    TableName = list_to_atom("ameo_" ++ integer_to_list(Partition)),
    TableId = ets:new(TableName, [set, {write_concurrency, false},
                                  {read_concurrency, false}]),
	TopicTableId = ets:new(TableName, [set, {write_concurrency, false},
									   {read_concurrency, false}]),

    {ok, #state{partition=Partition, table_id=TableId,
                table_name=TableName, topic_table=TopicTableId}}.

%% Sample command: respond to a ping
handle_command(ping, _Sender, State) ->
    {reply, {pong, State#state.partition}, State};

handle_command({cmd, Command, Args, Pid}, _Sender, State) ->
    Result = run_cmd(Command, Args, Pid, State),
    lager:info("~p ~p -> ~p", [Command, Args, Result]),
    {reply, Result, State};

handle_command(Message, _Sender, State) ->
    ?LOG_WARNING("unhandled_command ~p", [Message]),
    {noreply, State}.

handle_handoff_command(_Message, _Sender, State) ->
    {noreply, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(_Data, State) ->
    {reply, ok, State}.

encode_handoff_item(_ObjectName, _ObjectValue) ->
    <<>>.

handle_overload_command(_, _, _) ->
    ok.

handle_overload_info(_, _Idx) ->
    ok.

is_empty(State) ->
    {true, State}.

delete(State) ->
    {ok, State}.

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, Reason}, State) ->
    lager:info("Pid down, unsubscribing ~p ~p", [Pid, Reason]),
    unsubscribe_pid(Pid, State),
    {ok, State};
handle_info({gen_event_EXIT, {ameo_channel, _Pid}, _Reason}, State) ->
    {ok, State};
handle_info(Info, State) ->
    lager:info("Got vnode info ~p", [Info]),
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% private
run_cmd(<<"SET">>, [Key, Value], _Pid,
        #state{table_id=TableId, partition=Partition}) ->
    ets:insert(TableId, {Key, Value}),
    {ok, Partition};
run_cmd(<<"GET">>, [Key], _Pid,
        #state{table_id=TableId, partition=Partition}) ->
    case ets:lookup(TableId, Key) of
        [] ->
            {ok, Partition, nil};
        [{_, Value}] ->
            {ok, Partition, Value}
    end;
run_cmd(<<"DEL">>, [Key], _Pid,
        #state{table_id=TableId, partition=Partition}) ->
    case ets:lookup(TableId, Key) of
        [] ->
            {ok, Partition, 0};
        [_Value] ->
            true = ets:delete(TableId, Key),
            {ok, Partition, 1}
    end;
run_cmd(<<"SUBSCRIBE">>, [Topic], Pid, State) ->
	Channel = get_or_create_channel(Topic, State),
    lager:info("Subscribe ~p ~p", [Topic, Pid]),
    erlang:monitor(process, Pid),
    ameo_channel:subscribe(Channel, Pid),
    no_reply;
run_cmd(<<"UNSUBSCRIBE">>, [Topic], Pid, State=#state{partition=Partition}) ->
    case get_existing_channel(Topic, State) of
        nil ->
            {error, Partition, {not_subscribed, "Not Subscribed", Topic}};
        Channel ->
            ameo_channel:unsubscribe(Channel, Pid),
            {ok, Partition}
    end;
run_cmd(<<"PUBLISH">>, [Topic, Value], _Pid,
        State=#state{partition=Partition}) ->
    SubscriberCount = case get_existing_channel(Topic, State) of
                          nil -> 0;
                          Channel ->
                              ameo_channel:send(Channel, {pubsub_msg, Value}),
                              ameo_channel:subscriber_count(Channel)
                      end,
    lager:info("Publish to topic ~p with ~p subscribers", [Topic, SubscriberCount]),
    {ok, Partition, SubscriberCount};
run_cmd(Cmd, Args, _Pid, #state{partition=Partition}) ->
    {error, Partition, {unknown_command, "Unknown command", {Cmd, Args}}}.

unsubscribe_pid(Pid, #state{topic_table=TableId}) ->
    % FIXME: ineficient yet easy solution
    ets:foldl(fun ({Topic, Channel}, AccIn) ->
                      lager:info("FIXME: Blindly unsubscribing ~p from ~p just in case", [Pid, Topic]),
                      ameo_channel:unsubscribe(Channel, Pid),
                      AccIn
              end,
              unused_accum_state,
              TableId).

get_existing_channel(Topic, #state{topic_table=TableId}) ->
    case ets:lookup(TableId, Topic) of
        [] -> nil;
        [{_, Channel}] -> Channel
    end.

get_or_create_channel(Topic, State=#state{topic_table=TableId}) ->
    case get_existing_channel(Topic, State) of
        nil ->
            {ok, Channel} = ameo_channel:start_link(),
            ets:insert(TableId, {Topic, Channel}),
            lager:info("New channel for topic ~p ~p", [Topic, Channel]),
            Channel;
        Channel ->
            Channel
    end.
