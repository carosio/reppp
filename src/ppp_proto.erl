-module(ppp_proto).

%% Initialization procedure
-callback start_link(Link :: pid(), Config :: list()) -> {ok, pid()}.

%% Process a received packet
-callback frame_in(FSM :: pid(), Frame :: term()) -> ok.

%% Lower layer has come up
-callback lowerup(FSM :: pid()) -> ok.

%% Lower layer has gone down
-callback lowerdown(FSM :: pid()) -> ok.

%% Open the protocol
-callback loweropen(FSM :: pid()) -> ok.

%% Close the protocol
-callback lowerclose(FSM :: pid(), Reason :: binary()) -> ok.
