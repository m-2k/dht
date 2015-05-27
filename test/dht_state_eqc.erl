-module(dht_state_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-record(state,{
	init = false,
	time = 0, %% Current notion of where we are time-wise (in ms)
	id % The NodeID the node is currently running under
}).

api_spec() ->
	#api_spec {
		language = erlang,
		modules =
		  [
		  	#api_module {
		  		name = dht_routing,
		  		functions = [
		  			#api_fun { name = export, arity = 1 },
		  			#api_fun { name = new, arity = 1 },
		  			#api_fun { name = node_list, arity = 1},
		  			#api_fun { name = neighbors, arity = 3 },
		  			#api_fun { name = is_member, arity = 2 },
		  			#api_fun { name = refresh_node, arity = 2 },
		  			#api_fun { name = node_timer_state, arity = 2 },
		  			#api_fun { name = remove_node, arity = 2 },
		  			#api_fun { name = node_timeout, arity = 2 }
		  		]
		  	},
		  	#api_module {
		  		name = dht_net,
		  		functions = [
		  			#api_fun { name = ping, arity = 1 }
		  		]
		  	},
		  	#api_module {
		  		name = dht_time,
		  		functions = [
		  			#api_fun { name = monotonic_time, arity = 0},
		  			#api_fun { name = convert_time_unit, arity = 3 }
		  		]
		  	}
		  ]
	}.

%% GENERATORS
%% -----------------

%% Commands we are skipping:
%% 
%% We skip the state load/store functions. Mostly due to jlouis@ not thinking this is where the bugs are
%% nor is it the place where interesting interactions happen:
%%
%% * load_state/2
%% * dump_state/0, dump_state/1, dump_state/2
%%

%% INITIAL STATE
%% -----------------------

gen_initial_state() ->
    ?LET(NodeID, dht_eqc:id(),
      #state { id = NodeID, init = false }).

%% START_LINK
%% -----------------------

start_link(NodeID, Nodes) ->
    {ok, Pid} = dht_state:start_link(NodeID, no_state_file, Nodes),
    unlink(Pid),
    erlang:is_process_alive(Pid).
    
start_link_pre(S) -> not initialized(S).

start_link_args(#state { id = ID }) ->
    BootStrapNodes = [],
    [ID, BootStrapNodes].

start_link_callouts(#state { id = ID }, [ID, []]) ->
    ?CALLOUT(dht_routing, new, [?WILDCARD], {ok, ID, rt_ref}),
    ?RET(true).

%% Once started, we can't start the State system again.
start_link_next(State, _, _) ->
    State#state { init = true }.

%% NODE ID
%% ---------------------
node_id() ->
	dht_state:node_id().

node_id_pre(S) -> initialized(S).
	
node_id_args(_S) -> [].
	
node_id_callouts(#state { id = ID }, []) -> ?RET(ID).

%% NODE LIST
%% ---------------------
node_list() ->
	dht_state:node_list().
	
node_list_pre(S) -> initialized(S).

node_list_args(_S) -> [].

node_list_callouts(_S, []) ->
    ?MATCH(R, ?CALLOUT(dht_routing, node_list, [rt_ref], list(dht_eqc:peer()))),
    ?RET(R).

%% PING
%% ---------------------
ping_pre(#state { init = S }) -> S.

ping(IP, Port) ->
    dht_state:ping(IP, Port).

ping_args(_S) ->
    [dht_eqc:ip(), dht_eqc:port()].

%% TODO: also generate valid ping responses.
ping_callouts(_S, [IP, Port]) ->
    ?MATCH(R, ?CALLOUT(dht_net, ping, [{IP, Port}], oneof([pang]))),
    case R of
        pang -> ?RET(pang);
        ID ->
            ?APPLY(request_success, [{ID, IP, Port}]),
            ?RET(ID)
    end.

%% CLOSEST TO
%% ------------------------
closest_to_pre(#state { init = S }) -> S.

closest_to(ID, Num) ->
    dht_state:closest_to(ID, Num).
	
closest_to_args(_S) ->
    [dht_eqc:id(), nat()].
	
closest_to_callouts(_S, [ID, Num]) ->
    ?MATCH(Ns, ?CALLOUT(dht_routing, neighbors, [ID, Num, rt_ref],
        list(dht_eqc:peer()))),
    ?RET(Ns).

%% KEEPALIVE
%% ---------------------------
keepalive_pre(#state { init = S }) -> S.

keepalive(Node) ->
    dht_state:keepalive(Node).
	
keepalive_args(_S) ->
    [dht_eqc:peer()].
	
keepalive_callouts(_S, [{_, IP, Port} = Node]) ->
    ?MATCH(R, ?APPLY(ping, [IP, Port])),
    case R of
        pang -> ?APPLY(request_timeout, [Node]);
        _ID -> ?RET(ok)
    end.
    
%% REQUEST_SUCCESS
%% ----------------

request_success(Node) ->
    dht_state:request_success(Node).
    
request_success_pre(S) -> initialized(S).

request_success_args(_S) ->
    [dht_eqc:peer()].
    
request_success_callouts(_S, [Node]) ->
    ?MATCH(Member,
      ?CALLOUT(dht_routing, is_member, [Node, rt_ref], bool())),
    case Member of
        false -> ?RET(ok);
        true ->
          ?CALLOUT(dht_routing, refresh_node, [Node, rt_ref], rt_ref),
          ?RET(ok)
    end.

%% REQUEST_TIMEOUT
%% ----------------

request_timeout(Node) ->
    dht_state:request_timeout(Node).
    
request_timeout_pre(S) -> initialized(S).

request_timeout_args(_S) ->
    [dht_eqc:peer()].

request_timeout_callouts(_S, [Node]) ->
    ?MATCH(Member,
      ?CALLOUT(dht_routing, is_member, [Node, rt_ref], bool())),
    case Member of
        false -> ?RET(ok);
        true ->
          ?CALLOUT(dht_routing, node_timeout, [Node, rt_ref], rt_ref),
          ?MATCH(R, ?CALLOUT(dht_routing, node_timer_state, [Node, rt_ref],
              oneof([good, bad, {questionable, nat()}]))),
          case R of
            good -> ?RET(ok);
            {questionable, _} -> ?RET(ok);
            bad ->
              ?CALLOUT(dht_routing, remove_node, [Node, rt_ref], rt_ref),
              ?RET(ok)
          end
    end.

%% MODEL CLEANUP
%% ------------------------------

reset() ->
	case whereis(dht_state) of
	    undefined -> ok;
	    Pid when is_pid(Pid) ->
	        exit(Pid, kill),
	        timer:sleep(1)
	end,
	ok.

%% PROPERTY
%% -----------------------
postcondition_common(S, Call, Res) ->
    eq(Res, return_value(S, Call)).

prop_state_correct() ->
    ?SETUP(fun() ->
        eqc_mocking:start_mocking(api_spec()),
        fun() -> eqc_mocking:stop_mocking(), ok end
    end,
    ?FORALL(StartState, gen_initial_state(),
    ?FORALL(Cmds, commands(?MODULE, StartState),
        begin
            ok = reset(),
            {H, S, R} = run_commands(?MODULE, Cmds),
            pretty_commands(?MODULE, Cmds, {H, S, R},
                collect(eqc_lib:summary('Length'), length(Cmds),
                aggregate(command_names(Cmds),
                  R == ok)))
        end))).

%% INTERNAL MODEL HELPERS
%% -----------------------

initialized(#state { init = I }) -> I.