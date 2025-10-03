% Behavior-equivalent chat server rewritten with different internal design.
% Public API remains: start/1, stop/1. Message contracts are preserved.

-module(server).
-export([start/1, stop/1]).

%% ===== Server (coordinator) =====
-record(hub_state, {
    rooms = [],   % list of channel atoms
    roster = []   % list of nick strings (global uniqueness)
}).

start(ServerAtom) ->
    genserver:start(ServerAtom, new_hub_state(), fun hub_handle/2).

stop(ServerAtom) ->
    %% Attempt graceful stop of all channels, then stop the hub itself.
    catch_stop_all(ServerAtom),
    genserver:stop(ServerAtom).

new_hub_state() -> #hub_state{}.

%% Server message handler
hub_handle(St = #hub_state{rooms = Rooms, roster = Names}, {join, Room, Pid, Nick}) ->
    %% Ensure nickname exists in roster (idempotent add)
    St1 = ensure_nick(St, Nick),
    case lists:member(Room, Rooms) of
        true ->
            case channel_join(Room, Pid) of
                ok -> {reply, ok, St1};
                user_already_joined -> {reply, user_already_joined, St1};
                server_not_reached -> {reply, server_not_reached, St1}
            end;
        false ->
            start_room(Room, Pid),
            {reply, ok, St1#hub_state{rooms = [Room | Rooms]}}
    end;

hub_handle(St = #hub_state{roster = Names}, {nick, OldNick, NewNick}) ->
    case lists:member(NewNick, Names) of
        true -> {reply, nick_taken, St};
        false -> {reply, ok, St#hub_state{roster = [NewNick | lists:delete(OldNick, Names)]}}
    end;

hub_handle(St = #hub_state{rooms = Rooms}, stop_all) ->
    [genserver:stop(R) || R <- Rooms],
    {reply, ok, St#hub_state{rooms = []}};

hub_handle(St, _) -> {reply, idle, St}.

ensure_nick(St = #hub_state{roster = Names}, Nick) ->
    case lists:member(Nick, Names) of
        true -> St;
        false -> St#hub_state{roster = [Nick | Names]}
    end.

catch_stop_all(ServerAtom) ->
    try genserver:request(ServerAtom, stop_all) of
        ok -> ok
    catch
        throw:timeout_error -> server_not_reached;
        error:badarg -> server_not_reached
    end.

channel_join(Room, Pid) ->
    try genserver:request(Room, {join, Pid}) of
        ok -> ok;
        user_already_joined -> user_already_joined
    catch
        throw:timeout_error -> server_not_reached;
        error:badarg -> server_not_reached
    end.

start_room(Room, FirstPid) ->
    genserver:start(Room, init_room_state(FirstPid, Room), fun room_handle/2).

%% ===== Channel (room) =====
-record(room_state, {
    members = [],  % list of PIDs in the room
    id              % atom: registered name of the room
}).

init_room_state(FirstPid, RoomId) ->
    #room_state{members = [FirstPid], id = RoomId}.

room_handle(St = #room_state{members = Pids}, {join, Pid}) ->
    case lists:member(Pid, Pids) of
        true -> {reply, user_already_joined, St};
        false -> {reply, ok, St#room_state{members = [Pid | Pids]}}
    end;

room_handle(St = #room_state{members = Pids}, {leave, Pid}) ->
    case lists:member(Pid, Pids) of
        true -> {reply, ok, St#room_state{members = lists:delete(Pid, Pids)}};
        false -> {reply, user_not_joined, St}
    end;

room_handle(St = #room_state{members = Pids, id = Name}, {message_send, From, Nick, Msg}) ->
    case lists:member(From, Pids) of
        true ->
            spawn(fun() -> fanout(Name, Nick, Msg, Pids, From) end),
            {reply, ok, St};
        false -> {reply, user_not_joined, St}
    end;

room_handle(St, _) -> {reply, idle, St}.

fanout(Room, Nick, Message, Receivers, Sender) ->
    Others = lists:delete(Sender, Receivers),
    lists:foreach(fun(R) -> deliver(Room, Nick, Message, R) end, Others).

deliver(Room, Nick, Message, Receiver) ->
    try genserver:request(Receiver, {message_receive, atom_to_list(Room), Nick, Message}) of
        ok -> ok
    catch
        throw:timeout_error -> user_cannot_be_reached
    end.