%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Basho Technologies Inc. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License. You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied. See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @private

-module(erl_mesos_http).

-export([async_request/6, sync_request/6, body/1]).

-export([async_response/1, close_async_response/1]).

-export([handle_sync_response/1]).

-type headers() :: [{binary(), binary()}].
-export_type([headers/0]).

-type options() :: [{atom(), term()}].
-export_type([options/0]).

-type client_ref() :: hackney:client_ref().
-export_type([client_ref/0]).

-type response() :: {status, non_neg_integer(), binary()} |
                    {headers, headers()} |
                    binary() |
                    done |
                    {error, term()}.

%% External functions.

%% @doc Sends async http request.
-spec async_request(binary(), erl_mesos_data_format:data_format(), module(),
                    headers(), erl_mesos_data_format:message(), options()) ->
    {ok, client_ref()} | {error, term()}.
async_request(Url, DataFormat, DataFormatModule, Headers, Message, Options) ->
    Headers1 = request_headers(DataFormat, Headers),
    Body = erl_mesos_data_format:encode(DataFormat, DataFormatModule, Message),
    Options1 = async_request_options(Options),
    request(post, Url, Headers1, Body, Options1).

%% @doc Sends sync http request.
-spec sync_request(binary(), erl_mesos_data_format:data_format(), module(),
                   headers(), erl_mesos_data_format:message(), options()) ->
    {ok, non_neg_integer(), headers(), client_ref()} | {error, term()}.
sync_request(Url, DataFormat, DataFormatModule, Headers, Message, Options) ->
    Headers1 = request_headers(DataFormat, Headers),
    Body = erl_mesos_data_format:encode(DataFormat, DataFormatModule, Message),
    Options1 = sync_request_options(Options),
    request(post, Url, Headers1, Body, Options1).

%% @doc Receives http request body.
-spec body(client_ref()) -> {ok, binary()} | {error, term()}.
body(ClientRef) ->
    hackney:body(ClientRef).

%% @doc Returns async response.
-spec async_response({async_response, client_ref(), response()} | term()) ->
    {async_response, client_ref(), response()} | undefined.
async_response({hackney_response, ClientRef, Response})
  when is_reference(ClientRef) ->
    {async_response, ClientRef, Response};
async_response(_Info) ->
    undefined.

%% @doc Closes async response.
-spec close_async_response(client_ref()) -> ok | {error, term()}.
close_async_response(ClientRef) ->
    hackney:close(ClientRef).

%% @doc Handles sync response.
%% @private
-spec handle_sync_response({ok, non_neg_integer(), headers(), reference()} |
                           {error, term()}) ->
    ok | {error, term()} |
    {error, {http_response, non_neg_integer(), binary()}}.
handle_sync_response(Response) ->
    case Response of
        {ok, 202, _Headers, ClientRef} ->
            case erl_mesos_http:body(ClientRef) of
                {ok, _Body} ->
                    ok;
                {error, Reason} ->
                    {error, Reason}
            end;
        {ok, Status, _Headers, ClientRef} ->
            case erl_mesos_http:body(ClientRef) of
                {ok, Body} ->
                    {error, {http_response, Status, Body}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Internal functions.

%% @doc Returns request headers.
%% @private
-spec request_headers(erl_mesos_data_format:data_format(), headers()) ->
    headers().
request_headers(DataFormat, Headers) ->
    ContentType = erl_mesos_data_format:content_type(DataFormat),
    [{<<"Content-Type">>, ContentType},
     {<<"Accept">>, ContentType},
     {<<"Connection">>, <<"close">>}] ++
    Headers.

%% @doc Returns async request options.
%% @private
-spec async_request_options(options()) -> options().
async_request_options(Options) ->
    Keys = [async, recv_timeout, following_redirect],
    Options1 = [Option || {Key, _Value} = Option <- Options,
                not lists:member(Key, Keys)],
    Options2 = lists:delete(async, Options1),
    [async, {recv_timeout, infinity}, {following_redirect, false} | Options2].

%% @doc Returns sync request options.
%% @private
-spec sync_request_options(options()) -> options().
sync_request_options(Options) ->
    proplists:delete(async, lists:delete(async, Options)).

%% @doc Sends http request.
-spec request(atom(), binary(), headers(), binary(), options()) ->
    {ok, client_ref()} | {ok, non_neg_integer(), headers(), client_ref()} |
    {error, term()}.
request(Method, Url, Headers, Body, Options) ->
    hackney:request(Method, Url, Headers, Body, Options).
