%%--------------------------------------------------------------------
%% CCHAT client (reworded strings)
%%--------------------------------------------------------------------
-module(client).
-export([initial_state/3, handle/2]).

-record(cst, {
    gui,        %% registered gen_server name of the GUI
    nick,       %% current nickname (string)
    server      %% registered gen_server name of the chat hub
}).

%% Do not change signature (called by GUI bootstrap)
initial_state(Nick, GuiName, ServerName) ->
    #cst{gui = GuiName, nick = Nick, server = ServerName}.

%%========================
%% Core dispatcher (GUI -> Client)
%% Must always return {reply, Data, NewState}
%%========================

%% /join #channel
handle(S = #cst{nick = N, server = Srv}, {join, ChStr}) ->
    Ch = chan_to_atom(ChStr),
    case safe_req(Srv, {join, Ch, self(), N}) of
        ok -> {reply, ok, S};
        user_already_joined ->
            {reply, {error, user_already_joined,
                     "Already a member of that channel"}, S};
        server_not_reached ->
            {reply, {error, server_not_reached, "No reply from channel"}, S};
        server_down ->
            {reply, {error, server_not_reached, "No reply from server"}, S}
    end;

%% /leave [#channel]
handle(S, {leave, ChStr}) ->
    Ch = chan_to_atom(ChStr),
    case safe_req(Ch, {leave, self()}) of
        ok -> {reply, ok, S};
        user_not_joined ->
            {reply, {error, user_not_joined,
                     "Cannot leave: you are not in that channel"}, S};
        _ ->
            {reply, {error, server_not_reached, "No response from channel"}, S}
    end;

%% post a message in a channel
handle(S = #cst{nick = N}, {message_send, ChStr, Msg}) ->
    Ch = chan_to_atom(ChStr),
    case safe_req(Ch, {message_send, self(), N, Msg}) of
        ok -> {reply, ok, S};
        user_not_joined ->
            {reply, {error, user_not_joined,
                     "Cannot post: join the channel first"}, S};
        badarg_on_channel ->
            {reply, {error, server_not_reached,
                     "No response from channel (client likely not a member)"}, S};
        _ ->
            {reply, {error, server_not_reached, "No response from channel"}, S}
    end;

%% /nick newnick  (distinction: server enforces global uniqueness)
handle(S = #cst{nick = Old, server = Srv}, {nick, New}) ->
    case safe_req(Srv, {nick, Old, New}) of
        ok         -> {reply, ok, S#cst{nick = New}};
        nick_taken -> {reply, {error, nick_taken, "Nickname is in use; choose another"}, S};
        _          -> {reply, {error, server_not_reached, "No reply from server"}, S}
    end;

%% /whoami
handle(S = #cst{nick = N}, whoami) ->
    {reply, N, S};

%% Server -> Client push (forward to GUI for rendering)
handle(S = #cst{gui = GUI}, {message_receive, ChannelStr, FromNick, Msg}) ->
    %% GUI is a gen_server; keep protocol intact
    gen_server:call(GUI, {message_receive, ChannelStr, FromNick ++ ": " ++ Msg}),
    {reply, ok, S};

%% /quit
handle(S, quit) ->
    {reply, ok, S};

%% Unknown
handle(S, _Other) ->
    {reply, {error, not_implemented, "Unhandled command on client"}, S}.

%%========================
%% Internals
%%========================
chan_to_atom(Str) when is_list(Str) -> list_to_atom(Str);
chan_to_atom(A)   when is_atom(A)   -> A.

%% Standard wrapper around genserver:request/2
safe_req(Target, Msg) ->
    try genserver:request(Target, Msg) of
        X -> X
    catch
        throw:timeout_error -> classify_timeout(Msg);
        error:badarg        -> classify_badarg(Msg)
    end.

classify_timeout({join, _, _, _}) -> server_down;
classify_timeout({nick, _, _})    -> server_down;
classify_timeout(_)               -> server_not_reached.

classify_badarg({join, _, _, _})          -> server_down;
classify_badarg({nick, _, _})             -> server_down;
classify_badarg({message_send, _, _, _})  -> badarg_on_channel;
classify_badarg(_)                        -> server_not_reached.
