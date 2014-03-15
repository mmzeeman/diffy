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

-module(diffy_simple_patch).

-export([make_patch/1, apply_patch/2]).


%% Make a simple patch with edit operations.
%%
make_patch(Diffs) ->
    make_patch(Diffs, []).

%% @doc Make a simple patch. Removes the data from equal and delete 
%% operations and replaces it with a line and char count.
make_patch([], [{copy, _, _}]) ->
    [];
make_patch([], Acc) ->
    lists:reverse(Acc);
make_patch([{insert, _}=H|Rest], Acc) ->
    make_patch(Rest, [H|Acc]);
make_patch([{Op, Data}|Rest], Acc) ->
    {NoLines, NoChars} = count_lines(Data),
    make_patch(Rest, [{patch_op(Op), NoLines, NoChars}|Acc]).

patch_op(delete) -> skip;
patch_op(equal) -> copy.

%% @doc Return a tuple {NumberOfLines, NumberOfRemainderCharacters}
count_lines(Bin) ->
    count_lines(Bin, 0, 0, 0).

count_lines(Bin, Idx, Lines, Chars) when Idx > size(Bin) ->
    {Lines, Chars};
count_lines(Bin, Idx, Lines, Chars) ->
    case binary:match(Bin, <<"\n">>, [{scope, {Idx, size(Bin) - Idx}}]) of
        nomatch ->
            <<_:Idx/binary, Rest/binary>> = Bin,
            {Lines, count_chars(Rest, 0)};
        {Start, _} ->
            count_lines(Bin, Start+1, Lines+1, Chars)
    end.

%% @doc Return the number of remainder characters
count_chars(<<>>, Count) ->
    Count;
count_chars(<<_C/utf8, Rest/binary>>, Count) ->
    count_chars(Rest, Count+1).


% @doc Use the SourceText to reconstruct the destination text.
apply_patch(SourceText, Diffs) ->
    apply_patch(SourceText, 0, Diffs, []).

apply_patch(SourceText, Idx, [], Acc) ->
    erlang:iolist_to_binary(lists:reverse(Acc));
apply_patch(SourceText, Idx, [{insert, Data}|Rest], Acc) ->
    apply_patch(SourceText, Idx, Rest, [Data|Acc]);
apply_patch(SourceText, Idx, [{copy, Lines, Chars}|Rest], Acc) ->
    LineData = get_lines(SourceText, Idx, Lines),
    CharData = get_chars(SourceText, Idx+size(LineData), Chars),
    %% Get the data from the source-text.
    apply_patch(SourceText, Idx+size(LineData)+size(CharData), Rest, [CharData, LineData|Acc]);
apply_patch(SourceText, Idx, [{skip, Lines, Chars}|Rest], Acc) ->
    LineData = get_lines(SourceText, Idx, Lines),
    CharData = get_chars(SourceText, Idx+size(LineData), Chars),
    %% Advance the index
    apply_patch(SourceText, Idx+size(LineData)+size(CharData), Rest, Acc).

%% Get the data from N lines.
get_lines(Source, Idx, Lines) ->
    get_lines(Source, Idx, Lines, <<>>).

get_lines(Source, Idx, 0, Acc) ->
    Acc;
get_lines(Source, Idx, Lines, Acc) ->
    case binary:match(Source, <<"\n">>, [{scope, {Idx, size(Source) - Idx}}]) of
        nomatch ->
            Acc;
        {Start, _} ->
            LineSize = Start-Idx+1,
            <<_:Idx/binary, Line:LineSize/binary, Rest/binary>> = Source,
            get_lines(Source, Start+1, Lines-1, <<Acc/binary, Line/binary>>)
    end.

%% @doc Get the chardata for NChars from Source.
get_chars(Source, Idx, Chars) ->
    get_chars(Source, Idx, Chars, <<>>).

get_chars(Source, Idx, 0, CharData) ->
    CharData;
get_chars(Source, Idx, Chars, CharData) ->
    <<_:Idx/binary, C/utf8, _/binary>> = Source,
    S = size(<<C/utf8>>),
    get_chars(Source, Idx+S, Chars-1, <<CharData/binary, C/utf8>>).


%%
%% Tests
%%

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

make_patch_test() ->
    ?assertEqual([], make_patch([])),
    ?assertEqual([], make_patch([{equal, <<"foo">>}])),
    ?assertEqual([{copy, 1, 0}, {insert, <<"test">>}], 
            make_patch([{equal, <<"foo\n">>}, {insert, <<"test">>}])),

    ok.

count_lines_test() ->
    ?assertEqual({1, 0}, count_lines(<<"hoi\n">>)),
    ?assertEqual({2, 0}, count_lines(<<"hoi\ndaar\n">>)),
    ?assertEqual({3, 0}, count_lines(<<"\n\n\n">>)),
    ?assertEqual({0, 0}, count_lines(<<"">>)),
    ?assertEqual({0, 3}, count_lines(<<"hoi">>)),
    ?assertEqual({1, 5}, count_lines(<<"hoi\r\ndaar", 200/utf8>>)),

    ok.

get_lines_test() ->
    ?assertEqual(<<"hoi\n">>, get_lines(<<"hoi\n">>, 0, 1)),
    ?assertEqual(<<"hoi\n\n">>, get_lines(<<"hoi\n\n">>, 0, 2)),
    ?assertEqual(<<"oi\n\n">>, get_lines(<<"hoi\n\n">>, 1, 2)),
    ok.

get_chars_test() ->
    ?assertEqual(<<"h">>, get_chars(<<"hoi\n">>, 0, 1)),
    ?assertEqual(<<"oi">>, get_chars(<<"hoi\n">>, 1, 2)),
    ?assertEqual(<<"i\n">>, get_chars(<<"hoi\n">>, 2, 2)),
    ok.

apply_patch_test() ->
    A = <<"the cat\n\n   is in the hat\n">>,
    B = <<"the rabbit eats\n\n a carrot\n  in the hat\n">>,

    Diffs = diffy:diff(A, B),
    CDiffs = diffy:cleanup_efficiency(Diffs),
    Patch = make_patch(CDiffs),

    %% Check if the transformation worked.
    ?assertEqual(B, erlang:iolist_to_binary(apply_patch(A, Patch))),

    ok.


-endif.
