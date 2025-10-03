% A behavior-preserving rewrite of the client logic with the same public API.
% The module still exposes initial_state/3 and handle/2 with identical
% semantics, but the internal structure and code organization are different.

-module(client).
-export([handle/2, initial_state/3]).

%% Internal state (renamed fields; only used within this module)
-record(cl_st, {
    ui,     % GUI process (registered atom for OTP gen_server)
    alias,  % current nickname (string)
    hub     % server process (registered atom for custom genserver)
}).

%% Create initial state (called by GUI)
%% Do not change signature
initial_state(Nick, GUIAtom, ServerAtom) ->
    #cl_st{ui = GUIAtom, alias = Nick, hub = ServerAtom}.

%% Core dispatcher for GUI -> Client requests
%% Must return {reply, Data, NewState}

%% Join a channel
handle(St = #cl_st{alias = Nick, hub = Server}, {join, ChannelStr}) ->
    Chan = to_channel_atom(ChannelStr),
    case safe_request(Server, {join, Chan, self(), Nick}) of
        ok -> {reply, ok, St};
        user_already_joined ->
            {reply, {error, user_already_joined,
                     "this Channel CANNOT be joined as the User is already a Member of this Channel"}, St};
        server_not_reached ->
            {reply, {error, server_not_reached, "the Channel did not respond"}, St};
        server_down ->
            {reply, {error, server_not_reached, "the Server did not respond"}, St}
    end;

%% Leave a channel
handle(St, {leave, ChannelStr}) ->
    Chan = to_channel_atom(ChannelStr),
    case safe_request(Chan, {leave, self()}) of
        ok -> {reply, ok, St};
        user_not_joined ->
            {reply, {error, user_not_joined,
                     "this Channel cannot be left as the User is NOT a Member of this Channel"}, St};
        _ ->
            {reply, {error, server_not_reached, "the Channel did not respond"}, St}
    end;

%% Send message to a channel
handle(St = #cl_st{alias = Nick}, {message_send, ChannelStr, Msg}) ->
    Chan = to_channel_atom(ChannelStr),
    case safe_request(Chan, {message_send, self(), Nick, Msg}) of
        ok -> {reply, ok, St};
        user_not_joined ->
            {reply, {error, user_not_joined,
                     "this Channel CANNOT be written to as the User is not a Member of this Channel"}, St};
        badarg_on_channel ->
            {reply, {error, server_not_reached,
                     "the Channel did not respond (maybe because the client is not a member of it)"}, St};
        _ ->
            {reply, {error, server_not_reached, "the Channel did not respond"}, St}
    end;

%% Change nick (distinction task: global uniqueness enforced by server)
handle(St = #cl_st{alias = OldNick, hub = Server}, {nick, NewNick}) ->
    case safe_request(Server, {nick, OldNick, NewNick}) of
        ok -> {reply, ok, St#cl_st{alias = NewNick}};
        nick_taken ->
            {reply, {error, nick_taken, "CANNOT change nick because it is already taken"}, St};
        _ ->
            {reply, {error, server_not_reached, "the Server did not respond"}, St}
    end;

%% Helper/utility commands
handle(St, whoami) ->
    {reply, St#cl_st.alias, St};

%% Incoming message from a channel -> forward to GUI for rendering
handle(St = #cl_st{ui = GUI}, {message_receive, Channel, Nick, Msg}) ->
    gen_server:call(GUI, {message_receive, Channel, Nick ++ "> " ++ Msg}),
    {reply, ok, St};

%% Quit via GUI (placeholder for cleanup)
handle(St, quit) ->
    {reply, ok, St};

%% Fallback
handle(St, _) ->
    {reply, {error, not_implemented, "Client does not handle this command"}, St}.

%% ===== Internal helpers =====

to_channel_atom(ChannelStr) when is_list(ChannelStr) ->
    %% Keep behavior identical: allow creating atoms from strings
    list_to_atom(ChannelStr);
to_channel_atom(A) when is_atom(A) -> A.

%% Wrap custom genserver:request/2 with consistent error mapping
safe_request(Target, Payload) ->
    try genserver:request(Target, Payload) of
        Res -> Res
    catch
        throw:timeout_error ->
            %% Distinguish server vs channel context by Payload
            server_context(Payload);
        error:badarg ->
            badarg_context(Payload)
    end.

server_context({join, _Chan, _Pid, _Nick}) -> server_down;
server_context({nick, _Old, _New}) -> server_down;
server_context(_) -> server_not_reached.

badarg_context({join, _Chan, _Pid, _Nick}) -> server_down;
badarg_context({nick, _Old, _New}) -> server_down;
badarg_context({message_send, _Pid, _Nick, _Msg}) -> badarg_on_channel;
badarg_context(_) -> server_not_reached.