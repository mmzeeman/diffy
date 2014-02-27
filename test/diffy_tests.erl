%% @author Maas-Maarten Zeeman <mmzeeman@xs4all.nl>
%% @copyright 2014 Maas-Maarten Zeeman
%%
%% @doc Diffy, an erlang diff match and patch implementation 
%%
%% Copyright 2014 Maas-Maarten Zeeman
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
%% Erlang diff-match-patch implementation

-module(diffy_tests).

-include_lib("eunit/include/eunit.hrl").


pretty_html_test() ->
    ?assertEqual([], diffy:pretty_html([])),
    ?assertEqual([<<"<span>>test</span>">>], diffy:pretty_html([{equal, <<"test">>}])),
    ?assertEqual([<<"<del style='background:#ffe6e6;'>foo</del>">>, 
        <<"<span>>test</span>">>], diffy:pretty_html([{delete, <<"foo">>}, {equal, <<"test">>}])),
    ?assertEqual([<<"<ins style='background:#e6ffe6;'>foo</ins>">>, 
        <<"<span>>test</span>">>], diffy:pretty_html([{insert, <<"foo">>}, {equal, <<"test">>}])),
    ok.

source_text_test() ->
    ?assertEqual(<<"fruit flies like a banana">>, 
        diffy:source_text([{equal,<<"fruit flies ">>}, {delete,<<"lik">>}, {equal,<<"e">>},
            {insert,<<"at">>}, {equal,<<" a banana">>}])),
    ok.

destination_text_test() ->
    ?assertEqual(<<"fruit flies eat a banana">>, 
        diffy:destination_text([{equal,<<"fruit flies ">>}, {delete,<<"lik">>}, {equal,<<"e">>},
            {insert,<<"at">>}, {equal,<<" a banana">>}])),
    ok.


levenshtein_test() ->
    ?assertEqual(0, diffy:levenshtein([])),
    ?assertEqual(5, diffy:levenshtein([{equal,<<"fruit flies ">>}, {delete,<<"lik">>}, 
        {equal,<<"e">>}, {insert,<<"at">>}, {equal,<<" a banana">>}])),

    % Levenshtein with trailing equality.
    ?assertEqual(4, diffy:levenshtein([{delete, <<"abc">>}, {insert, <<"1234">>}, {equal, <<"xyz">>}])),
    % Levenshtein with leading equality.
    ?assertEqual(4, diffy:levenshtein([{equal, <<"xyz">>}, {delete, <<"abc">>}, {insert, <<"1234">>}])),
    % Levenshtein with middle equality.
    ?assertEqual(7, diffy:levenshtein([{delete, <<"abc">>}, {equal, <<"xyz">>}, {insert, <<"1234">>}])),

    ok.