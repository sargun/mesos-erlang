-module(erl_mesos_scheduler2).

-behaviour(gen_server).

-include("erl_mesos.hrl").

-export([start_link/3]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {scheduler :: module(),
                data_format :: erl_mesos_data_format:data_format(),
                master_hosts :: [binary()],
                subscribe_req_options :: [{atom(), term()}],
                heartbeat_timeout_window :: pos_integer(),
                max_num_resubscribe :: non_neg_integer(),
                resubscribe_interval :: non_neg_integer(),
                framework_info :: undefined | framework_info(),
                force :: undefined | boolean(),
                scheduler_state :: undefined | term(),
                master_hosts_queue :: undefined | [binary()],
                master_host :: undefined | binary(),
                client_ref :: undefined | reference(),
                subscribe_state :: undefined | subscribe_state(),
                framework_id :: undefined | framework_id(),
                num_redirect = 0 :: non_neg_integer(),
                num_resubscribe = 0 :: non_neg_integer(),
                heartbeat_timeout :: pos_integer(),
                heartbeat_timer_ref :: undefined | reference(),
                resubscribe_timer_ref :: undefined | reference()}).

-record(subscribe_response, {status :: undefined | non_neg_integer(),
                             headers :: undefined | [{binary(), binary()}]}).

-record(scheduler_info, {data_format :: erl_mesos_data_format:data_format(),
                         master_host :: binary(),
                         framework_id :: framework_id()}).

-type options() :: [{atom(), term()}].
-export_type([options/0]).

-type state() :: #state{}.

-type subscribe_response() :: subscribe_response().

-type subscribe_state() :: subscribe_response() | subscribed.

-type scheduler_info() :: #scheduler_info{}.

%% Callbacks.

-callback init(term()) ->
    {ok, framework_info(), boolean(), term()} | {stop, term()}.

-callback registered(scheduler_info(), subscribed_event(), term()) ->
    {ok, term()} | {stop, term()}.

-define(DEFAULT_MASTER_HOSTS, [<<"localhost:5050">>]).

-define(DEFAULT_SUBSCRIBE_REQ_OPTIONS, []).

-define(DEFAULT_MAX_REDIRECT, 5).

-define(DEFAULT_HEARTBEAT_TIMEOUT_WINDOW, 5000).

-define(DEFAULT_MAX_NUM_RESUBSCRIBE, 1).

-define(DEFAULT_RESUBSCRIBE_INTERVAL, 0).

-define(DATA_FORMAT, json).

%% External functions.

%% @doc Starts the `erl_mesos_scheduler' process.
-spec start_link(module(), term(), options()) -> {ok, pid()} | {error, term()}.
start_link(Scheduler, SchedulerOptions, Options) ->
    gen_server:start_link(?MODULE, {Scheduler, SchedulerOptions, Options}, []).

%% gen_server callback functions.

%% @private
-spec init({module(), term(), options()}) -> {ok, state()}.
init({Scheduler, SchedulerOptions, Options}) ->
    case init(Scheduler, SchedulerOptions, Options) of
        {ok, State} ->
            {ok, State};
        {error, Reason} ->
            {stop, Reason}
    end.

%% @private
-spec handle_call(term(), {pid(), term()}, state()) ->
    {stop, {error, {call, term()}}, state()}.
handle_call(Request, _From, State) ->
    {stop, {error, {call, Request}}, State}.

%% @private
-spec handle_cast(term(), state()) ->
    {stop, {error, {cast, term()}}, state()}.
handle_cast(Request, State) ->
    {stop, {error, {cast, Request}}, State}.

%% @private
-spec handle_info(term(), state()) ->
    {noreply, state()} | {stop, term(), state()}.
handle_info({hackney_response, ClientRef, Response},
            #state{client_ref = ClientRef} = State) ->
    handle_subscribe_response(Response, State);
handle_info({'DOWN', ClientRef, _Reason},
            #state{client_ref = ClientRef} = State) ->
    maybe_subscribe(State);
handle_info(Info, State) ->
    io:format("Info ~p~n", [Info]),
    {noreply, State}.

%% @private
-spec terminate(term(), state()) -> term().
terminate(_Reason, _State) ->
    ok.

%% @private
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions.

%% @doc Returns master hosts.
%% @private
-spec master_hosts(options()) ->
    {ok, {master_hosts, [binary()]}} | {error, {bad_master_host, term()}} |
    {error, {bad_master_hosts, term()}}.
master_hosts(Options) ->
    case erl_mesos_options:get_value(master_hosts, Options,
                                     ?DEFAULT_MASTER_HOSTS) of
        MasterHosts when is_list(MasterHosts) andalso length(MasterHosts) > 0 ->
            case master_hosts(MasterHosts, []) of
                {ok, ValidMasterHosts} ->
                    {ok, {master_hosts, ValidMasterHosts}};
                {error, MasterHost} ->
                    {error, {bad_master_host, MasterHost}}
            end;
        MasterHosts ->
            {error, {bad_master_hosts, MasterHosts}}
    end.

%% @doc Validates and converts master hosts.
%% @private
-spec master_hosts([term()], [binary()]) -> {ok, [binary()]} | {error, term()}.
master_hosts([MasterHost | MasterHosts], ValidMasterHosts)
  when is_binary(MasterHost) ->
    master_hosts(MasterHosts, [MasterHost | ValidMasterHosts]);
master_hosts([MasterHost | MasterHosts], ValidMasterHosts)
  when is_list(MasterHost) ->
    master_hosts(MasterHosts, [binary_to_list(MasterHost) | ValidMasterHosts]);
master_hosts([MasterHost | _MasterHosts], _ValidMasterHosts) ->
    {error, MasterHost};
master_hosts([], ValidMasterHosts) ->
    {ok, lists:reverse(ValidMasterHosts)}.

%% @doc Returns subscribe request options.
%% @private
-spec subscribe_req_options(options()) ->
    {ok, {subscribe_req_options, [{atom(), term()}]}} |
    {error, {bad_subscribe_req_options, term()}}.
subscribe_req_options(Options) ->
    case erl_mesos_options:get_value(subscribe_req_options, Options,
                                     ?DEFAULT_SUBSCRIBE_REQ_OPTIONS) of
        SubscribeReqOptions when is_list(SubscribeReqOptions) ->
            DeleteKeys = [async, recv_timeout, following_redirect],
            SubscribeReqOptions1 = [{async, once},
                                    {recv_timeout, infinity},
                                    {following_redirect, false}] ++
                erl_mesos_options:delete(DeleteKeys, SubscribeReqOptions),
            {ok, {subscribe_req_options, SubscribeReqOptions1}};
        SubscribeReqOptions ->
            {error, {bad_subscribe_req_options, SubscribeReqOptions}}
    end.

%% @doc Returns heartbeat timeout window.
%% @private
-spec heartbeat_timeout_window(options()) ->
    {ok, {heartbeat_timeout_window, non_neg_integer()}} |
    {error, {bad_heartbeat_timeout_window, term()}}.
heartbeat_timeout_window(Options) ->
    case erl_mesos_options:get_value(heartbeat_timeout_window, Options,
                                     ?DEFAULT_HEARTBEAT_TIMEOUT_WINDOW) of
        HeartbeatTimeoutWindow
          when is_integer(HeartbeatTimeoutWindow) andalso
               HeartbeatTimeoutWindow >= 0 ->
            {ok, {heartbeat_timeout_window, HeartbeatTimeoutWindow}};
        HeartbeatTimeoutWindow ->
            {error, {bad_heartbeat_timeout_window, HeartbeatTimeoutWindow}}
    end.

%% @doc Returns maximum numumber of resubscribe.
%% @private
-spec max_num_resubscribe(options()) ->
    {ok, {max_num_resubscribe, non_neg_integer() | infinity}} |
    {error, {bad_max_num_resubscribe, term()}}.
max_num_resubscribe(Options) ->
    case erl_mesos_options:get_value(max_num_resubscribe, Options,
                                     ?DEFAULT_MAX_NUM_RESUBSCRIBE) of
        MaxNumResubscribe
          when is_integer(MaxNumResubscribe) andalso MaxNumResubscribe >=0 ->
            {ok, {max_num_resubscribe, MaxNumResubscribe}};
        MaxNumResubscribe ->
            {error, {bad_max_num_resubscribe, MaxNumResubscribe}}
    end.

%% @doc Returns resubscribe interval.
%% @private
-spec resubscribe_interval(options()) ->
    {ok, {resubscribe_interval, non_neg_integer()}} |
    {error, {bad_resubscribe_interval, term()}}.
resubscribe_interval(Options) ->
    case erl_mesos_options:get_value(resubscribe_interval, Options,
                                     ?DEFAULT_RESUBSCRIBE_INTERVAL) of
        ResubscribeInterval
          when is_integer(ResubscribeInterval) andalso
               ResubscribeInterval >= 0 ->
            {ok, {resubscribe_interval, ResubscribeInterval}};
        ResubscribeInterval ->
            {error, {bad_resubscribe_interval, ResubscribeInterval}}
    end.

%% @doc Returns validated options.
%% @private
-spec options([fun((options()) -> {ok, {atom(), term()}} | {error, term()})],
  options()) ->
    {ok, options()} | {error, term()}.
options(Funs, Options) when is_list(Options) ->
    options(Funs, Options, []);
options(_Funs, Options) ->
    {error, {bad_options, Options}}.

%% @doc Returns validated options.
%% @private
-spec options([fun((options()) -> {ok, {atom(), term()}} | {error, term()})],
  options(), options()) ->
    {ok, options()} | {error, term()}.
options([Fun | Funs], Options, ValidOptions) ->
    case Fun(Options) of
        {ok, Option} ->
            options(Funs, Options, [Option | ValidOptions]);
        {error, Reason} ->
            {error, Reason}
    end;
options([], _Options, ValidOptions) ->
    {ok, ValidOptions}.

%% @doc Validates options and sets options to the state.
%% @private
-spec init(module(), term(), options()) -> {ok, state()} | {error, term()}.
init(Scheduler, SchedulerOptions, Options) ->
    Funs = [fun master_hosts/1,
            fun subscribe_req_options/1,
            fun heartbeat_timeout_window/1,
            fun max_num_resubscribe/1,
            fun resubscribe_interval/1],
    case options(Funs, Options) of
        {ok, ValidOptions} ->
            State = state(Scheduler, ValidOptions),
            case init(SchedulerOptions, State) of
                {ok, State1} ->
                    subscribe(State1);
                {stop, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Returns state.
%% @private
-spec state(module(), options()) -> state().
state(Scheduler, Options) ->
    MasterHosts = erl_mesos_options:get_value(master_hosts, Options),
    SubscribeReqOptions = erl_mesos_options:get_value(subscribe_req_options,
                                                      Options),
    HeartbeatTimeoutWindow =
        erl_mesos_options:get_value(heartbeat_timeout_window, Options),
    MaxNumResubscribe = erl_mesos_options:get_value(max_num_resubscribe,
                                                    Options),
    ResubscribeInterval = erl_mesos_options:get_value(resubscribe_interval,
                                                      Options),
    #state{scheduler = Scheduler,
           data_format = ?DATA_FORMAT,
           master_hosts = MasterHosts,
           subscribe_req_options = SubscribeReqOptions,
           heartbeat_timeout_window = HeartbeatTimeoutWindow,
           max_num_resubscribe = MaxNumResubscribe,
           resubscribe_interval = ResubscribeInterval}.

%% @doc Calls Scheduler:init/1.
%% @private
-spec init(term(), state()) -> {ok, state()} | {stop, term()}.
init(SchedulerOptions, #state{master_hosts = MasterHosts,
                              scheduler = Scheduler} = State) ->
    case Scheduler:init(SchedulerOptions) of
        {ok, FrameworkInfo, Force, SchedulerState}
          when is_record(FrameworkInfo, framework_info), is_boolean(Force) ->
            {ok, State#state{framework_info = FrameworkInfo,
                             force = Force,
                             scheduler_state = SchedulerState,
                             master_hosts_queue = MasterHosts}};
        {stop, Reason} ->
            {stop, Reason}
    end.

%% @doc Sends subscribe requests.
%% @private
-spec subscribe(state()) -> {ok, state()} | {error, bad_hosts}.
subscribe(#state{master_hosts_queue = [MasterHost | MasterHostsQueue]} =
          State) ->
    case subscribe(MasterHost, State) of
        {ok, ClientRef} ->
            {ok, State#state{master_hosts_queue = MasterHostsQueue,
                             master_host = MasterHost,
                             client_ref = ClientRef}};
        {error, _Reason} ->
            subscribe(State#state{master_hosts_queue = MasterHostsQueue})
    end;
subscribe(#state{master_hosts_queue = []}) ->
    {error, bad_hosts}.

%% @doc Sends subscribe request.
%% @private
-spec subscribe(binary(), state()) ->
    {ok, hackney:client_ref()} | {error, term()}.
subscribe(MasterHost, #state{data_format = DataFormat,
                             subscribe_req_options = SubscribeReqOptions,
                             framework_info = FrameworkInfo,
                             force = Force,
                             framework_id = undefined}) ->
    erl_mesos_api:subscribe(DataFormat, MasterHost, SubscribeReqOptions,
                            FrameworkInfo, Force).



%% @doc Handles subscribe response.
%% @private
-spec handle_subscribe_response(term(), state()) ->
    {noreply, state()} | {stop, term(), state()}.
handle_subscribe_response({status, Status, _Message},
                          #state{client_ref = ClientRef,
                                 subscribe_state = undefined} = State) ->
    SubscribeResponse = #subscribe_response{status = Status},
    hackney:stream_next(ClientRef),
    {noreply, State#state{subscribe_state = SubscribeResponse}};
handle_subscribe_response({headers, Headers},
                          #state{client_ref = ClientRef,
                                 subscribe_state =
                                 #subscribe_response{headers = undefined} =
                                 SubscribeResponse} = State) ->
    SubscribeResponse1 = SubscribeResponse#subscribe_response{headers =
                                                              Headers},
    hackney:stream_next(ClientRef),
    {noreply, State#state{subscribe_state = SubscribeResponse1}};
handle_subscribe_response(Events,
                          #state{subscribe_state =
                                 #subscribe_response{status = 200}} = State) ->
    decode_events(Events, State);
handle_subscribe_response(Events,
                          #state{subscribe_state = subscribed} = State)
  when is_binary(Events) ->
    decode_events(Events, State);
%% handle 307 redirect here.
%% hanlde 503 error here.
%% handle_subscribe_response(done, State) ->
%%     do_subscribe(State);
%% handle_subscribe_response({error, _Reason}, State) ->
%%     do_subscribe(State);
handle_subscribe_response(_, State) ->
    maybe_subscribe(State).


maybe_subscribe(#state{framework_id = undefined} = State) ->
    case subscribe(State) of
        {ok, State1} ->
            {noreply, State1};
        {error, Reason} ->
            {stop, {shutdown, {subscribe, {error, Reason}}}, State}
    end.




%% @doc Decodes list of events.
%% @private
-spec decode_events(binary(), state()) ->
    {noreply, state()} | {stop, term(), state()}.
decode_events(Events, #state{data_format = DataFormat,
                             client_ref = ClientRef} = State) ->
    Objs = erl_mesos_data_format:decode_events(DataFormat, Events),
    case handle_events(Objs, State) of
        {ok, State1} ->
            hackney:stream_next(ClientRef),
            {noreply, State1};
        {stop, State1} ->
            {stop, shutdown, State1}
    end.

%% @doc Handles list of events.
%% @private
-spec handle_events([erl_mesos_obj:data_obj()], state()) ->
    {ok, state()} | {stop, state()}.
handle_events([Obj | Objs], State) ->
    case handle_event(Obj, State) of
        {ok, State1} ->
            handle_events(Objs, State1);
        {stop, State1} ->
            {stop, State1}
    end;
handle_events([], State) ->
    {ok, State}.

%% @doc Handles event.
%% @private
-spec handle_event(erl_mesos_obj:data_obj(), state()) ->
    {ok, state()} | {stop, state()}.
handle_event(Obj, #state{subscribe_state = SubscribeState,
                         framework_id = FrameworkId} = State) ->
    case erl_mesos_scheduler_event:parse_obj(Obj) of
        {subscribed, {#subscribed_event{framework_id = SubscribeFrameworkId} =
                      SubscribedEvent, HeartbeatTimeout}}
          when is_record(SubscribeState, subscribe_response),
               FrameworkId =:= undefined ->
            State1 = State#state{subscribe_state = subscribed,
                                 framework_id = SubscribeFrameworkId,
                                 num_redirect = 0,
                                 num_resubscribe = 0,
                                 heartbeat_timeout = HeartbeatTimeout},
            call(registered, SubscribedEvent, set_heartbeat_timer(State1));
        {subscribed, {_SubscribedEvent, HeartbeatTimeout}}
          when is_record(SubscribeState, subscribe_response) ->
            State1 = State#state{subscribe_state = subscribed,
                                 num_redirect = 0,
                                 num_resubscribe = 0,
                                 heartbeat_timeout = HeartbeatTimeout},
            call(reregistered, set_heartbeat_timer(State1));
        {error, ErrorEvent} ->
            call(error, ErrorEvent, State);
        heartbeat ->
            {ok, set_heartbeat_timer(State)};
        Event ->
            io:format("New unhandled event arrived: ~p~n", [Event]),
            {ok, State}
    end.

%% @doc Calls Scheduler:Callback/2.
%% @private
-spec call(atom(), state()) -> {ok, state()} | {stop, state()}.
call(Callback, #state{scheduler = Scheduler,
                      scheduler_state = SchedulerState} = State) ->
    SchedulerInfo = scheduler_info(State),
    case Scheduler:Callback(SchedulerInfo, SchedulerState) of
        {ok, SchedulerState1} ->
            {ok, State#state{scheduler_state = SchedulerState1}};
        {stop, SchedulerState1} ->
            {stop, State#state{scheduler_state = SchedulerState1}}
    end.

%% @doc Calls Scheduler:Callback/3.
%% @private
-spec call(atom(), term(), state()) -> {ok, state()} | {stop, state()}.
call(Callback, Arg, #state{scheduler = Scheduler,
                           scheduler_state = SchedulerState} = State) ->
    SchedulerInfo = scheduler_info(State),
    case Scheduler:Callback(SchedulerInfo, Arg, SchedulerState) of
        {ok, SchedulerState1} ->
            {ok, State#state{scheduler_state = SchedulerState1}};
        {stop, SchedulerState1} ->
            {stop, State#state{scheduler_state = SchedulerState1}}
    end.

%% @doc Returns scheduler info.
%% @private
-spec scheduler_info(state()) -> scheduler_info().
scheduler_info(#state{data_format = DataFormat,
                      master_hosts = MasterHosts,
                      framework_id = FrameworkId}) ->
    #scheduler_info{data_format = DataFormat,
                    master_host = MasterHosts,
                    framework_id = FrameworkId}.

%% @doc Sets heartbeat timer.
%% @private
-spec set_heartbeat_timer(state()) -> state().
set_heartbeat_timer(#state{heartbeat_timeout_window = HeartbeatTimeoutWindow,
                           heartbeat_timeout = HeartbeatTimeout,
                           heartbeat_timer_ref = HeartbeatTimerRef} =
                    State) ->
    cancel_heartbeat_timer(HeartbeatTimerRef),
    Timeout = HeartbeatTimeout + HeartbeatTimeoutWindow,
    HeartbeatTimerRef1 = erlang:start_timer(Timeout, self(), heartbeat),
    State#state{heartbeat_timer_ref = HeartbeatTimerRef1}.

%% @doc Cancels heartbeat timer.
%% @private
-spec cancel_heartbeat_timer(undefined | reference()) ->
    undefined | false | non_neg_integer().
cancel_heartbeat_timer(undefined) ->
    undefined;
cancel_heartbeat_timer(HeartbeatTimerRef) ->
    erlang:cancel_timer(HeartbeatTimerRef).

%% @doc Closes the subscribe connection.
%% @private
-spec close(undefined | reference()) -> ok | {error, term()}.
close(undefined) ->
    ok;
close(ClientRef) ->
    hackney:close(ClientRef).