%% 
%% %CopyrightBegin%
%% 
%% Copyright Ericsson AB 1996-2021. All Rights Reserved.
%% 
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%% 
%% %CopyrightEnd%
%%
-module(os_sup).
-behaviour(gen_server).

%% API
-export([start_link/1, start/0, stop/0]).
-export([error_report/2]).
-export([enable/0, enable/2, disable/0, disable/2]).
-export([param_type/2, param_default/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2]).

-record(state, {port, mfa, config, path, conf}).

%%----------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------

start_link({win32, _OSname}) ->
    Identifier = os_sup,
    MFA = os_mon:get_env(os_sup, os_sup_mfa),
    gen_server:start_link({local, os_sup_server}, nteventlog,
			  [Identifier, MFA], []);
start_link(_OS) ->
    gen_server:start_link({local, os_sup_server}, os_sup, [], []).

start() -> % for testing
    gen_server:start({local, os_sup_server}, os_sup, [], []).

stop() ->
    gen_server:call(os_sup_server, stop).

error_report(LogData, Tag) ->
    error_logger:error_report(Tag, LogData).

-spec enable() -> ok | {error, Res} when
      Res :: string().
enable() ->
    command(enable).
-spec enable(Dir, Conf) -> ok | {error, Res} when
      Dir :: string(),
      Conf :: string(),
      Res :: string().
enable(Path, Conf) ->
    command(enable, Path, Conf).

-spec disable() -> ok | {error, Res} when
      Res :: string().
disable() ->
    command(disable).
-spec disable(Dir, Conf) -> ok | {error, Res} when
      Dir :: string(),
      Conf :: string(),
      Res :: string().
disable(Path, Conf) ->
    command(disable, Path, Conf).

param_type(os_sup_errortag, Val) when is_atom(Val) -> true;
param_type(os_sup_own, Val) -> io_lib:printable_list(Val);
param_type(os_sup_syslogconf, Val) -> io_lib:printable_list(Val);
param_type(os_sup_enable, Val) when Val==true; Val==false -> true;
param_type(os_sup_mfa, {Mod,Func,Args}) when is_atom(Mod),
					     is_atom(Func),
					     is_list(Args) -> true;
param_type(_Param, _Val) -> false.

param_default(os_sup_errortag) -> std_error;
param_default(os_sup_own) -> "/etc";
param_default(os_sup_syslogconf) -> "/etc/syslog.conf";
param_default(os_sup_enable) -> true;
param_default(os_sup_mfa) -> {os_sup, error_report, [std_error]}.

%%----------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------

init([]) ->
    process_flag(trap_exit, true),
    process_flag(priority, low),

    case os:type() of
	{unix, sunos} ->
	    init2();
	OS -> {stop, {unsupported_os, OS}}
    end.

init2() -> % Enable service if configured to do so
    ConfigP = os_mon:get_env(os_sup, os_sup_enable),
    case ConfigP of
	true -> % ..yes -- do enable
	    Path = os_mon:get_env(os_sup, os_sup_own),
	    Conf = os_mon:get_env(os_sup, os_sup_syslogconf),
	    case enable(Path, Conf) of
		ok ->
		    init3(#state{config=ConfigP, path=Path, conf=Conf});
		{error, Error} ->
		    {stop, {mod_syslog, Error}}
	    end;
	false -> % ..no -- skip directly to init3/1
	    init3(#state{config=ConfigP})
    end.

init3(State0) ->
    Port = start_portprogram(),

    %% Read the values of some configuration parameters
    MFA = case os_mon:get_env(os_sup, os_sup_mfa) of
	      {os_sup, error_report, _} ->
		  Tag = os_mon:get_env(os_sup, os_sup_errortag),
		  {os_sup, error_report, [Tag]};
	      MFA0 ->
		  MFA0
	  end,

    {ok, State0#state{port=Port, mfa=MFA}}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({_Port, {data, Data}}, #state{mfa={M,F,A}} = State) ->
    apply(M, F, [Data | A]),
    {noreply, State};
handle_info({'EXIT', _Port, Reason}, State) ->
    {stop, {port_died, Reason}, State#state{port=not_used}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{port=Port} = State) ->
    case State#state.config of
	true when is_port(Port) ->
	    Port ! {self(), {command, "only_stdin"}},
	    Res = disable(State#state.path, State#state.conf),
	    port_close(Port),
	    if
		Res/="0" -> exit({mod_syslog, Res});
		true -> ok
	    end;
	true ->
	    Res = disable(State#state.path, State#state.conf),
	    if
		Res/="0" -> exit({mod_syslog, Res});
		true -> ok
	    end;
	false when is_port(Port) ->
	    Port ! {self(), {command, "only_stdin"}},
	    port_close(Port);
	false ->
	    ok
    end.

%%----------------------------------------------------------------------
%% Internal functions
%%----------------------------------------------------------------------

start_portprogram() ->
    OwnPath = os_mon:get_env(os_sup, os_sup_own),
    Command =
	"\"" ++ filename:join([code:priv_dir(os_mon), "bin", "ferrule"]) ++
	"\" " ++ OwnPath,
    open_port({spawn, Command}, [{packet, 2}]).

%% os:cmd(cmd_str(enable)) should be done BEFORE starting os_sup
%% os:cmd(cmd_str(disable)) should be done AFTER os_sup is terminated
%% Both commands return "0" if successful
command(Mode) ->
    command(Mode, "/etc", "/etc/syslog.conf").
command(Mode, Path, Conf) ->
    case os:cmd(cmd_str(Mode, Path, Conf)) of
	"0" ->
	    ok;
	Error ->
	    {error, Error}
    end.

cmd_str(Mode, Path, Conf) ->
    %% modpgm modesw ownpath syslogconf
    PrivDir = code:priv_dir(os_mon),
    ModeSw =
	case Mode of
	    enable ->
		" otp ";
	    disable ->
		" nootp "
	end,
    PrivDir ++ "/bin/mod_syslog" ++ ModeSw ++ Path ++ " " ++ Conf.
