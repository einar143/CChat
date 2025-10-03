-module(client).
-export([handle/2, initial_state/3]).

% This record defines the structure of the state of a client.
-record(client_st, {
    gui,    % atom of the GUI process
    nick,   % nick/username of the client (string)
    server  % atom of the chat server (registered name)
}).

% Return an initial state record. This is called from GUI.
% Do not change the signature of this function.
initial_state(Nick, GUIAtom, ServerAtom) ->
    #client_st{
        gui = GUIAtom,
        nick = Nick,
        server = ServerAtom
    }.

%% ------------------------------------------------------------------
%% Helpers
%% ------------------------------------------------------------------

-spec server_call(#client_st{}, term()) -> ok | {error, atom(), string()}.
server_call(St = #client_st{server = ServerAtom}, Req) ->
    try genserver:request(ServerAtom, Req, 3000) of
        Reply -> Reply
    catch
        throw:timeout_error ->
            {error, server_not_reached, "server not reached"};
        error:badarg ->
            {error, server_not_reached, "server not reached"};
        Class:Reason ->
            % Any other unexpected failure -> treat as server unreachable
            _ = {Class,Reason},
            {error, server_not_reached, "server not reached"}
    end.

%% ------------------------------------------------------------------
%% GUI -> Client requests
%% Must return {reply, DataToGUI, NewState}
%% DataToGUI is either 'ok', a string (for whoami), or {error,Atom,Text}
%% ------------------------------------------------------------------

% Join channel
handle(St, {join, Channel}) ->
    Reply = server_call(St, {join, St#client_st.nick, self(), Channel}),
    {reply, Reply, St};

% Leave channel
handle(St, {leave, Channel}) ->
    Reply = server_call(St, {leave, self(), Channel}),
    {reply, Reply, St};

% Sending message (from GUI, to channel)
handle(St, {message_send, Channel, Msg}) ->
    Reply = server_call(St, {message_send, St#client_st.nick, self(), Channel, Msg}),
    {reply, Reply, St};

% This case is only relevant for the distinction assignment!
% Change nick (no server-side uniqueness check here; local only)
handle(St, {nick, NewNick}) ->
    {reply, ok, St#client_st{nick = NewNick}};

% Optional: connect/disconnect/ping accepted by GUI, keep minimal semantics
handle(St, {connect, ServerName}) when is_list(ServerName) ->
    % Switch to another server name (local atom). Best-effort check.
    NewServer = list_to_atom(ServerName),
    _ = whereis(NewServer),  % touch to allow badarg in server_call elsewhere if not running
    {reply, ok, St#client_st{server = NewServer}};
handle(St, disconnect) ->
    {reply, ok, St};
handle(St, {ping, _Nick}) ->
    {reply, ok, St};

% ---------------------------------------------------------------------------
% The cases below do not need to be changed...
% But you should understand how they work!

% Get current nick
handle(St, whoami) ->
    {reply, St#client_st.nick, St};

% Incoming message (from server, via genserver {request,...})
handle(St = #client_st{gui = GUI}, {message_receive, Channel, Nick, Msg}) ->
    gen_server:call(GUI, {message_receive, Channel, Nick++"> "++Msg}),
    {reply, ok, St};

% Quit client via GUI
handle(St, quit) ->
    {reply, ok, St};

% Catch-all for any unhandled requests
handle(St, _Data) ->
    {reply, {error, not_implemented, "Client does not handle this command"}, St}.
