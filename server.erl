-module(server).
-export([start/1, stop/1]).

%% Internal
-define(INIT_STATE, #{channels => #{}}).

%% State shape:
%% #{ channels := #{ ChannelString => sets:set(Pid) } }

start(ServerAtom) ->
    % Start a genserver-compat loop registered as ServerAtom
    genserver:start(ServerAtom, ?INIT_STATE, fun handle/2).

stop(ServerAtom) ->
    genserver:stop(ServerAtom).

%% ------------------------------------------------------------------
%% Server request handler (called by genserver.erl)
%% Must return {reply, Reply, NewState}
%% ------------------------------------------------------------------

handle(State = #{channels := ChanMap}, {join, Nick, ClientPid, Channel}) ->
    _ = Nick, % Nick is carried for symmetry/debug; membership by Pid
    Members = maps:get(Channel, ChanMap, sets:new()),
    case sets:is_element(ClientPid, Members) of
        true ->
            {reply, {error, user_already_joined, "already joined"}, State};
        false ->
            NewMembers = sets:add_element(ClientPid, Members),
            NewMap = maps:put(Channel, NewMembers, ChanMap),
            {reply, ok, State#{channels := NewMap}}
    end;

handle(State = #{channels := ChanMap}, {leave, ClientPid, Channel}) ->
    Members = maps:get(Channel, ChanMap, sets:new()),
    
    case sets:is_element(ClientPid, Members) of
        false ->
            {reply, {error, user_not_joined, "not in channel"}, State};
        true ->
            NewMembers = sets:del_element(ClientPid, Members),
            NewMap = maps:put(Channel, NewMembers, ChanMap),
            {reply, ok, State#{channels := NewMap}}
    end;

handle(State = #{channels := ChanMap}, {message_send, Nick, ClientPid, Channel, Msg}) ->
    Members = maps:get(Channel, ChanMap, sets:new()),
    case sets:is_element(ClientPid, Members) of
        false ->
            {reply, {error, user_not_joined, "not in channel"}, State};
        true ->
            send_to_all(sets:to_list(Members), {message_receive, Channel, Nick, Msg}),
            {reply, ok, State}
    end;

% Unknown message: reply ok and keep state
handle(State, _Other) ->
    {reply, ok, State}.

%% ------------------------------------------------------------------
%% Helpers
%% ------------------------------------------------------------------

send_to_all([], _Msg) ->
    ok;
send_to_all([Pid | Rest], Msg) when is_pid(Pid) ->
    Ref = make_ref(),
    Pid ! {request, self(), Ref, Msg},
    receive
        {result, Ref, _Any} -> ok;
        {exit,   Ref, _R}   -> ok
    after 2000 ->
        ok
    end,
    send_to_all(Rest, Msg).
