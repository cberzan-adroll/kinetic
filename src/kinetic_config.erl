-module(kinetic_config).
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, terminate/2, code_change/3,
         handle_info/2]).

-export([start_link/1, update_data/1, stop/0, g/1, get_args/0]).

-include("kinetic.hrl").

-record(kinetic_config, {tref}).

-define(METADATA_BASE_URL, "http://169.254.169.254").

start_link(Opts) ->
    gen_server:start_link(
      {local, ?MODULE}, ?MODULE, [Opts], []).

stop() ->
    gen_server:call(?MODULE, stop).

g(Name) ->
    case application:get_env(kinetic, Name) of
        {ok, Value} ->
            Value;
        _ ->
            undefined
    end.

get_args() ->
    try ets:lookup_element(?KINETIC_DATA, ?KINETIC_ARGS_KEY, 2) of
        V ->
            {ok, V}
    catch
        error:badarg ->
            {error, missing_credentials}
    end.

update_data(Opts) ->
    Arguments = case get_args() of
        {error, missing_credentials} ->
            new_args(Opts);
        {ok, Result} ->
            update_data_subsequent(Opts, Result)
    end,
    ets:insert(?KINETIC_DATA, {?KINETIC_ARGS_KEY, Arguments}),
    {ok, Arguments}.

% gen_server behavior

init([Opts]) ->
    process_flag(trap_exit, true),
    ets:new(?KINETIC_DATA, [named_table, set, public, {read_concurrency, true}]),
    {ok, _ClientArgs} = update_data(Opts),
    case timer:apply_interval(1000, ?MODULE, update_data, [Opts]) of
        {ok, TRef} -> 
            {ok, #kinetic_config{tref=TRef}};
        Error ->
            {stop, Error}
    end.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast(_Arg, State) ->
    {noreply, State}.

terminate(_Reason, _State=#kinetic_config{tref=TRef}) ->
    {ok, cancel} = timer:cancel(TRef),
    true = ets:delete(?KINETIC_DATA),
    ok.

code_change(_OldVsn, State, _Extra) ->
    State.

handle_info(_Info, State) ->
    {noreply, State}.

% Internal implementation

% -spec region(zone()) -> region().
region("us-east-1" ++ _R) -> "us-east-1";
region("us-west-1" ++ _R) -> "us-west-1";
region("us-west-2" ++ _R) -> "us-west-2";
region("ap-northeast-1" ++ _R) -> "ap-northeast-1";
region("ap-southeast-1" ++ _R) -> "ap-southeast-1";
region("eu-west-1" ++ _R) -> "eu-west-1".

get_aws_credentials(V, P, MetaData, Role)
        when V =:= undefined orelse P =:= undefined ->
    {ok, {AccessKeyId, SecretAccessKey, Expiration}} = kinetic_iam:get_aws_keys(MetaData, Role),
    ExpirationSeconds = calendar:datetime_to_gregorian_seconds(kinetic_iso8601:parse(Expiration)),
    {ok, {AccessKeyId, SecretAccessKey, ExpirationSeconds}};
get_aws_credentials(AccessKeyId, SecretAccessKey, _, _) ->
    {ok, {AccessKeyId, SecretAccessKey, no_expire}}.

update_data_subsequent(_Opts, Args=#kinetic_arguments{expiration_seconds=no_expire}) ->
    Args#kinetic_arguments{date=isonow()};
update_data_subsequent(Opts, Args=#kinetic_arguments{expiration_seconds=CurrentExpirationSeconds}) ->
    SecondsToExpire = CurrentExpirationSeconds - calendar:datetime_to_gregorian_seconds(erlang:universaltime()),
    case SecondsToExpire < ?EXPIRATION_REFRESH of
        true ->
            new_args(Opts);
        false ->
            Args#kinetic_arguments{date=isonow()}
    end.

new_args(Opts) ->
    ConfiguredAccessKeyId = proplists:get_value(aws_access_key_id, Opts),
    ConfiguredSecretAccessKey = proplists:get_value(aws_secret_access_key, Opts),
    MetaData = proplists:get_value(metadata_base_url, Opts, ?METADATA_BASE_URL),
    {ok, Zone} = kinetic_utils:fetch_and_return_url(MetaData ++ "/latest/meta-data/placement/availability-zone", text),
    Region = region(Zone),
    LHttpcOpts = proplists:get_value(lhttpc_opts, Opts, []),
    Host = kinetic_utils:endpoint("kinesis", Region),
    Url = "https://" ++ Host,
    Role = proplists:get_value(iam_role, Opts),

    {ok, {AccessKeyId, SecretAccessKey, ExpirationSeconds}} = 
        get_aws_credentials(ConfiguredAccessKeyId, ConfiguredSecretAccessKey, MetaData, Role),

    #kinetic_arguments{access_key_id=AccessKeyId,
                       secret_access_key=SecretAccessKey,
                       region=Region,
                       date=isonow(),
                       host=Host,
                       url=Url,
                       expiration_seconds=ExpirationSeconds,
                       lhttpc_opts=LHttpcOpts}.

isonow() ->
    kinetic_iso8601:format_basic(erlang:universaltime()).

