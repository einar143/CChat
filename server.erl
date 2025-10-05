%%--------------------------------------------------------------------
%% CCHAT server (hub + rooms; wording adjusted)
%%--------------------------------------------------------------------
-module(server).
-export([start/1, stop/1]).

-record(hstate, {
    rooms  = #{},  %% #{ChannelAtom => Pid}
    roster = #{}   %% #{NickString => true}  (global uniqueness)
}).

%%========================
%% Public API
%%========================
start(ServerName) ->
    genserver:start(ServerName, #hstate{}, fun hub_handle/2).

stop(ServerName) ->
    %% Best-effort shutdown: ask hub to stop rooms, then stop hub
    _ = try genserver:request(ServerName, stop_all)
        catch _:_ -> server_not_reached
        end,
    genserver:stop(ServerName).

%%========================
%% Hub (coordinator)
%%========================
hub_handle(HS = #hstate{rooms = Rooms, roster = R}, {join, Room, ClientPid, Nick}) ->
    HS1 = ensure_nick(HS, Nick),
    case maps:get(Room, Rooms, undefined) of
        undefined ->
            Pid = start_room(Room, ClientPid),
            {reply, ok, HS1#hstate{rooms = Rooms#{Room => Pid}}};
        RoomPid ->
            case req_room(RoomPid, {join, ClientPid}) of
                ok                 -> {reply, ok, HS1};
                user_already_joined-> {reply, user_already_joined, HS1};
                server_not_reached -> {reply, server_not_reached, HS1}
            end
    end;

%% Global nick uniqueness (distinction)
hub_handle(HS = #hstate{roster = R}, {nick, Old, New}) ->
    case maps:is_key(New, R) of
        true  -> {reply, nick_taken, HS};
        false ->
            R1 = maps:remove(Old, R),
            {reply, ok, HS#hstate{roster = R1#{New => true}}}
    end;

%% Hub: stop all channels (used by stop/1)
hub_handle(HS = #hstate{rooms = Rooms}, stop_all) ->
    maps:map(fun(_Name, Pid) -> genserver:stop(Pid) end, Rooms),
    {reply, ok, HS#hstate{rooms = #{}}};

%% Default
hub_handle(HS, _Other) ->
    {reply, idle, HS}.

ensure_nick(HS = #hstate{roster = R}, Nick) ->
    case maps:is_key(Nick, R) of
        true  -> HS;
        false -> HS#hstate{roster = R#{Nick => true}}
    end.

req_room(RoomPid, Payload) ->
    try genserver:request(RoomPid, Payload) of
        X -> X
    catch
        throw:timeout_error -> server_not_reached;
        error:badarg        -> server_not_reached
    end.

start_room(RoomName, FirstPid) ->
    Init = r_init(RoomName, [FirstPid]),
    genserver:start(RoomName, Init, fun room_handle/2).

%%========================
%% Room (channel) process
%%========================
-record(rstate, {
    name,            %% channel name (atom, registered)
    members = []     %% [Pid]
}).

r_init(Name, InitialMembers) ->
    #rstate{name = Name, members = lists:usort(InitialMembers)}.

room_hand_
