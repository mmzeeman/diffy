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

-module(diffy).

-export([
    diff/2,
    diff_bisect/2,

    pretty_html/1,

    source_text/1,
    destination_text/1,

    cleanup_merge/1,
    cleanup_semantic/1,

    cleanup_efficiency/1,
    cleanup_efficiency/2,

    levenshtein/1,

    make_patch/1,
    make_patch/2,

    text_size/1
]).

-type diff_op() :: delete | equal | insert.
-type diff() :: {diff_op(), unicode:unicode_binary()}.
-type diffs() :: list(diff()).

-export_type([diffs/0]).

-define(PATCH_MARGIN, 4).
-define(PATCH_MAX_PATCH_LEN, 32).

-define(MATCH_MAXBITS, 31).

-define(IS_INS_OR_DEL(Op), (Op =:= insert orelse Op =:= delete)).

-record(bisect_state, {
    k1start = 0, k1end = 0,
    k2start = 0, k2end = 0,
    v1,
    v2
}).

-record(patch, {
    diffs = [],

    start1 = 0,
    start2 = 0,

    length1 = 0,
    length2 = 0
}).

% @doc Compute the difference between two binary texts
%
-spec diff(unicode:unicode_binary(), unicode:unicode_binary()) -> diffs().
diff(Text1, Text2) ->
    diff(Text1, Text2, true).

diff(<<>>, <<>>, _CheckLines) ->
    [];
diff(Text1, Text2, _CheckLines) when Text1 =:= Text2 ->
    [{equal, Text1}];
diff(Text1, Text2, CheckLines) ->
    {Prefix, MText1, MText2, Suffix} = split_pre_and_suffix(Text1, Text2),

    Diffs = compute_diff(MText1, MText2, CheckLines),

    Diffs1 = case Suffix of
        <<>> -> Diffs;
        _ -> Diffs ++ [{equal, Suffix}]
    end,

    Diffs2 = case Prefix of 
        <<>> -> Diffs1;
        _ -> [{equal, Prefix} | Diffs1]
    end,

    cleanup_merge(Diffs2).

%% This assumes Text1 and Text2 don't have a common prefix
compute_diff(<<>>, NewText, _CheckLines) ->
    [{insert, NewText}];
compute_diff(OldText, <<>>, _CheckLines) ->
    [{delete, OldText}];
compute_diff(OldText, NewText, CheckLines) ->
    %% Check if ShortText is inside LongText
    OldGtNew = size(OldText) < size(NewText),

    {ShortText, LongText} = case OldGtNew of
        true -> {OldText, NewText};
        false -> {NewText, OldText}
    end,

    %% TODO: check if this works for utf8 input.
    case binary:match(LongText, ShortText) of
        {Start, Length} ->
            <<Pre:Start/binary, _:Length/binary, Suf/binary>> = Long,
            Op = case OldGtNew of
                true -> delete;
                false -> insert
            end,
            [{Op, Pre}, {equal, Short}, {Op, Suf}]; 
        nomatch ->
            case size(ShortText) of
                1 ->
                    [{delete, OldText}, {insert, NewText}];
                _ ->
                    compute_diff1(OldText, NewText, CheckLines)
             end
    end.

single_char(<<>>) ->
    false;
single_char(<<C/utf8>>) ->
    true;
single_char(Bin) when is_binary(Bin) ->
    false.

%% Line diff
compute_diff1(Text1, Text2, true) ->
    compute_diff_linemode(Text1, Text2);
compute_diff1(Text1, Text2, false) when size(Text1) > 100 orelse size(Text2) > 100 ->
    compute_diff_linemode(Text1, Text2);
compute_diff1(Text1, Text2, false) ->
    diff_bisect(Text1, Text2).

%%
compute_diff_linemode(_Text1, _Text2) ->
    throw(not_yet).

%% Find the 'middle snake' of a diff, split the problem in two
%%      and return the recursively constructed diff.
%%      See Myers 1986 paper: An O(ND) Difference Algorithm and Its Variations.
%%
%%    Args:
%%      text1: Old string to be diffed.
%%      text2: New string to be diffed.
%%      deadline: Time at which to bail if not yet complete.
%%
%%    Returns:
%%      Array of diff tuples.
%%    """
diff_bisect(A, B) when is_binary(A) andalso is_binary(B) ->
    ArrA = array_from_binary(A),
    ArrB = array_from_binary(B),
    try compute_diff_bisect1(ArrA, ArrB, array:size(ArrA), array:size(ArrB)) of
        no_overlap -> 
            [{delete, A}, {insert, B}] 
    catch
        throw:{overlap, A1, B1, X, Y} ->
            diff_bisect_split(A1, B1, X, Y)
    end.

compute_diff_bisect1(A, B, M, N) ->
    %% TODO, add deadline... 
    MaxD = (M + N) div 2,

    VOffset = MaxD,
    VLength = 2 * MaxD,

    V1 = array:new(VLength, [{default, -1}]),
    V2 = array:set(VOffset + 1, 0, V1),
    
    Delta = M - N,

    % If the total number of characters is odd, then the front path will
    % collide with the reverse path.
    Front = (Delta rem 2 =/= 0),

    %% {K1Start, K1End, K2Start, K2End, V1, V2}
    State = #bisect_state{v1=V2, v2=V2},

    %% Loops
    for(0, MaxD, fun(D, S1) ->
        %% Walk the front path one step
        S3 = for(-D + S1#bisect_state.k1start, D + 1 - S1#bisect_state.k1end, 2, fun(K1, S2) ->
            K1Offset = VOffset + K1,

            X1 = case K1 =:= -D orelse (K1 =/= D andalso 
                    (array:get(K1Offset-1, S2#bisect_state.v1) < array:get(K1Offset+1, S2#bisect_state.v1))) of
                true -> array:get(K1Offset + 1, S2#bisect_state.v1);
                false -> array:get(K1Offset - 1, S2#bisect_state.v1) + 1
            end,

            Y1 = X1 - K1,
            {X1_1, Y1_1} = match_front(X1, Y1, A, M, B, N),
            S2_1 = S2#bisect_state{v1=array:set(K1Offset, X1_1, S2#bisect_state.v1)},
 
            if 
                X1_1 > M -> 
                    % Ran off the right of the graph...
                    V = S2_1#bisect_state.k1end + 2,
                    {continue, S2_1#bisect_state{k1end=V}};
                Y1_1 > N ->
                    % Ran off the bottom of the graph...
                    V = S2_1#bisect_state.k1start + 2,
                    {continue, S2_1#bisect_state{k1start=V}};
                Front ->
                    K2Offset = VOffset + Delta - K1,
                    V2AtOffset = array:get(K2Offset, S2_1#bisect_state.v2),
                    case K2Offset >= 0 andalso K2Offset < VLength andalso V2AtOffset =/= -1 of
                        true ->
                            % Mirror x2 onto top-left coordinate system.
                            X2 = M - V2AtOffset,
                            if 
                                X1_1 >= X2 ->
                                    % Overlap detected
                                    throw({overlap, A, B, X1_1, Y1_1});
                                true ->
                                    {continue, S2_1}
                            end;
                        false ->
                            {continue, S2_1}
                    end;
                true ->
                    {continue, S2_1}
            end
        end, S1),

        %% Walk the reverse path one step. (verdacht hetzelfde als het ding hierboven...)
        S5 = for(-D + S3#bisect_state.k2start, D + 1 - S3#bisect_state.k2end, 2, fun(K2, S4) ->
            K2Offset = VOffset + K2,
            X2 = case K2 =:= -D orelse (K2 =/= D andalso 
                        array:get(K2Offset-1, S4#bisect_state.v2) < array:get(K2Offset+1, S4#bisect_state.v2)) of
                true -> 
                    array:get(K2Offset + 1, S4#bisect_state.v2);
                false -> 
                    array:get(K2Offset - 1, S4#bisect_state.v2) + 1
            end,

            Y2 = X2 - K2,

            {X2_1, Y2_1} = match_reverse(X2, Y2, A, M, B, N),
            S4_1 = S4#bisect_state{v2=array:set(K2Offset, X2_1, S4#bisect_state.v2)},

            if 
                X2_1 > M -> 
                    % Ran off the right of the graph...
                    V = S4_1#bisect_state.k2end + 2,
                    {continue, S4_1#bisect_state{k2end=V}};
                Y2_1 > N ->
                    % Ran off the bottom of the graph...
                    V = S4_1#bisect_state.k2start + 2,
                    {continue, S4_1#bisect_state{k2start=V}};
                Front ->
                    K1Offset = VOffset + Delta - K2,
                    V1AtOffset = array:get(K1Offset, S4_1#bisect_state.v1),
                    case K1Offset >= 0 andalso K1Offset < VLength andalso V1AtOffset =/= -1 of
                        true ->
                            X1 = V1AtOffset,
                            Y1 = VOffset + X1 - K1Offset,
                            if 
                                % Mirror x2 onto top-left coordinate system.
                                X1 >= M - X2_1 ->
                                    % Overlap detected
                                    throw({overlap, A, B, X1, Y1});
                                true ->
                                    {continue, S4_1}
                            end;
                        false ->
                            {continue, S4_1}
                    end;
                true ->
                    {continue, S4_1}
            end
        end, S3),
        {continue, S5}
    end, State),

    no_overlap.

% @doc Split A and B and process the parts.
diff_bisect_split(A, B, X, Y) ->
    A1 = binary_from_array(0, X, A),
    A2 = binary_from_array(0, Y, B),

    B1 = binary_from_array(X, array:size(A), A),
    B2 = binary_from_array(Y, array:size(B), B),

    Diffs = diff(A1, A2, false),
    DiffsB = diff(B1, B2, false),

    Diffs ++ DiffsB.

% @doc Convert the diffs into a pretty html report
-spec pretty_html(diffs()) -> iolist().
pretty_html(Diffs) ->
    pretty_html(Diffs, []).

pretty_html([], Acc) ->
    lists:reverse(Acc);
pretty_html([{Op, Data}|T], Acc) ->
    Text = z_html:escape(Data),
    HTML = case Op of
        insert ->
            <<"<ins style='background:#e6ffe6;'>", Text/binary, "</ins>">>;
        delete ->
            <<"<del style='background:#ffe6e6;'>", Text/binary, "</del>">>;
        equal ->
            <<"<span>>", Text/binary, "</span>">>
    end,
    pretty_html(T, [HTML|Acc]).

% @doc Compute the source text from a list of diffs.
source_text(Diffs) ->
    source_text(Diffs, <<>>).

source_text([], Acc) ->
    Acc;
source_text([{insert, _Data}|T], Acc) ->
    source_text(T, Acc);
source_text([{_Op, Data}|T], Acc) ->
    source_text(T, <<Acc/binary, Data/binary>>).
    

% @doc Compute the destination text from a list of diffs.
destination_text(Diffs) ->
    destination_text(Diffs, <<>>).
    
destination_text([], Acc) -> 
    Acc;
destination_text([{delete, _Data}|T], Acc) ->
    destination_text(T, Acc);
destination_text([{_Op, Data}|T], Acc) ->
    destination_text(T, <<Acc/binary, Data/binary>>).
    
% @doc Compute the Levenshtein distance, the number of inserted, deleted or substituted characters.
levenshtein(Diffs) ->
    levenshtein(Diffs, 0, 0, 0).

levenshtein([], Insertions, Deletions, Levenshtein) ->
    Levenshtein + max(Insertions, Deletions);
levenshtein([{insert, Data}|T], Insertions, Deletions, Levenshtein) ->
    levenshtein(T, Insertions+text_size(Data), Deletions, Levenshtein);
levenshtein([{delete, Data}|T], Insertions, Deletions, Levenshtein) ->
    levenshtein(T, Insertions, Deletions+text_size(Data), Levenshtein);
levenshtein([{equal, _Data}|T], Insertions, Deletions, Levenshtein) ->
    levenshtein(T, 0, 0, Levenshtein+max(Insertions, Deletions)).


%@ @doc Cleanup diffs. 
% Remove empty operations, merge equal opearations, edits before equal operation and common prefix operations.
%
-spec cleanup_merge(diffs()) -> diffs().
cleanup_merge(Diffs) ->
    cleanup_merge(Diffs, []). 

%% Done
cleanup_merge([], Acc) ->
    lists:reverse(Acc);
%% Remove operations without data.
cleanup_merge([{Op, <<>>}|T], Acc) ->
    cleanup_merge(T, Acc);
%% Merge data from equal operations
cleanup_merge([{Op2, Data2}|T], [{Op1, Data1}|Acc]) when Op1 =:= Op2 ->
    cleanup_merge(T, [{Op1, <<Data1/binary, Data2/binary>>}|Acc]);
%% Cleanup edits before equal operation
cleanup_merge([{Op1, Data1}|T], [{Op2, _}=I, {Op3, Data3}|Acc]) when Op1 =/= Op2 andalso Op1 =:= Op3 andalso Op2 =/= equal andalso Op3 =/= equal ->
    cleanup_merge(T, [I, {Op3, <<Data3/binary, Data1/binary>>}|Acc]);
%% Check if Op1Data and Op2Data have common prefixes.
cleanup_merge([{equal, E1}|T], [{Op1, Op1Data}, {Op2, Op2Data}, {equal, E2}|Acc]) when Op1 =/= Op2 andalso Op1 =/= equal andalso Op2 =/= equal ->
    {Prefix, Op1DataD, Op2DataD, Suffix} = split_pre_and_suffix(Op1Data, Op2Data),
    cleanup_merge(T, [{equal, <<Suffix/binary, E1/binary>>}, 
        {Op1, Op1DataD}, {Op2, Op2DataD}, {equal, <<E2/binary, Prefix/binary>>}|Acc]);
%% Check for slide left and slide right edits
cleanup_merge([{equal, E1}=H|T], [{Op, I}, {equal, E2}|AccTail]=Acc) when Op =:= insert orelse Op =:= delete ->
    case is_suffix(E2, I) of
        false ->
            case is_prefix(E1, I) of
                false ->
                    cleanup_merge(T, [H|Acc]);
                true ->
                    P = size(E1),
                    <<_:P/binary, Post/binary>> = I,
                    cleanup_merge([{equal, <<E2/binary, E1/binary>>}, {Op, <<Post/binary, E1/binary>>}|T], AccTail)
            end;
        true ->
            R = size(I) - size(E2),
            <<Pre:R/binary,  Post/binary>> = I,
            cleanup_merge([{Op, <<E2/binary, Pre/binary>>}, {equal, <<Post/binary, E1/binary>>}|T], AccTail)
    end;
cleanup_merge([H|T], Acc) ->
    cleanup_merge(T, [H|Acc]).

% @doc Do semantic cleanup of diffs
%
-spec cleanup_semantic(diffs()) -> diffs().
cleanup_semantic(Diffs) ->
    cleanup_semantic(Diffs, []).

cleanup_semantic([], Acc) ->
    lists:reverse(Acc);
cleanup_semantic([H|T], Acc) ->
    cleanup_semantic(T, [H|Acc]).

% @doc Do efficiency cleanup of diffs.
%
-spec cleanup_efficiency(diffs()) -> diffs().
cleanup_efficiency(Diffs) ->
    cleanup_efficiency(Diffs, 4).

cleanup_efficiency(Diffs, EditCost) ->
    cleanup_efficiency(Diffs, false, EditCost, []).

%% Done.
cleanup_efficiency([], Changed, _EditCost, Acc) ->
    Diffs = lists:reverse(Acc),
    case Changed of
        false -> Diffs;
        true -> cleanup_merge(Diffs)
    end;
%% Any equality which is surrounded on both sides by an insertion and deletion need less then 
%% EditCost characters for it to be advantageous to split.
cleanup_efficiency([{O1, _}=A, {equal, XY}=E, {O2, _}=B | T], Changed, EditCost, Acc) when 
        O1 =/= O2 andalso ?IS_INS_OR_DEL(O1) andalso ?IS_INS_OR_DEL(O2) ->
    case text_smaller_than(XY, EditCost) of
        true ->
            %% Split
            Del = {delete, XY},
            Ins = {insert, XY},

            cleanup_efficiency([Ins, B | T], true, EditCost, [Del, A | Acc]);
        false ->
            %% Equal is big enough, move A and equal out of the way.
            cleanup_efficiency([B | T], Changed, EditCost, [E, A |Acc])
    end;
%% Any equality which is surrounded on one side by an existing insertion and deletion and on the 
%% other side by an exisiting insertion or deletion needs by less than half C characters long for it 
%% to be advantagous to split.
cleanup_efficiency([{O1, _}=A, {O2, _}=B, {equal, X}=E, {O3, _}=C | T], Changed, EditCost, Acc) when
    O1 =/= O2 andalso ?IS_INS_OR_DEL(O1) andalso ?IS_INS_OR_DEL(O2) andalso ?IS_INS_OR_DEL(O3) ->
    case text_smaller_than(X, EditCost div 2 + 1) of
        true ->
            %% Split
            Del = {delete, X},
            Ins = {insert, X},
            cleanup_efficiency([Ins, C | T], true, EditCost, [Del, B, A | Acc]);
        false ->
            %% Equal is big enough, move delete and equal out of the way.
            cleanup_efficiency([B, E, C | T], Changed, EditCost, [A |Acc])
    end;
cleanup_efficiency([H|T], Changed, EditCost, Acc) ->
    cleanup_efficiency(T, Changed, EditCost, [H|Acc]).


% @doc Return true iff the text is smaller than specified 
text_smaller_than(_, 0) ->
    false;
text_smaller_than(<<>>, _Size) ->
    true;
text_smaller_than(<<_C/utf8, Rest/binary>>, Size) when Size > 0 ->
    text_smaller_than(Rest, Size-1);
text_smaller_than(<<_C, Rest/binary>>, Size) when Size > 0 ->
    %% Illegal utf-8 string, just count this as a single character and continue
    text_smaller_than(Rest, Size-1).

% @doc create a patch from a list of diffs
make_patch(Diffs) when is_list(Diffs) ->
    %% Reconstruct the source-text from the diffs.
    make_patch(Diffs, source_text(Diffs)).

% @doc create a patch from the source and destination texts
make_patch(SourceText, DestinationText) when is_binary(SourceText) andalso is_binary(DestinationText) ->
    Diffs = diff(SourceText, DestinationText),
    Diffs1 = cleanup_semantic(Diffs),
    Diffs2 = cleanup_efficiency(Diffs1),
    make_patch(Diffs2, SourceText);

% @doc Creata a patch from a list of diffs and the source text.
make_patch(Diffs, SourceText) when is_list(Diffs) andalso is_binary(SourceText) ->
    make_patch(Diffs, SourceText, SourceText, 0, 0, [#patch{}]).

make_patch([], _PrePatchText, _PostPatchText, Count1, Count2, [Patch|Rest]=Patches) ->
    case Patch#patch.diffs of
        [] -> 
            lists:reverse(Rest);
        _ -> 
            lists:reverse(Patches)
    end;
    
make_patch([{insert, Data}=D|T], PrePatchText, PostPatchText, Count1, Count2, [Patch|Rest]) ->
    Diffs = [D|Patch#patch.diffs],
    Size = size(Data),

    L = Patch#patch.length2 + Size,
    P = Patch#patch{diffs=Diffs, length2=L},

    %% Insert the text into the postpatch text.
    <<Pre:Count2/binary, Post/binary>> = PostPatchText,
    NewPostPatchText = <<Pre/binary, Data/binary, Post/binary>>,

    make_patch(T, PrePatchText, NewPostPatchText, Count1, Count2+Size, [P|Rest]);

make_patch([{delete, Data}=D|T], PrePatchText, PostPatchText, Count1, Count2, [Patch|Rest]) ->
    Diffs = [D|Patch#patch.diffs],
    Size = size(Data),

    L = Patch#patch.length1 + Size,
    P = Patch#patch{diffs=Diffs, length1=L},

    %% Remove the piece of text.
    <<Pre:Count2/binary, _:Size/binary, Post/binary>> = PostPatchText,
    NewPostPatchText = <<Pre/binary, Post/binary>>,
    
    make_patch(T, PrePatchText, NewPostPatchText, Count1+Size, Count2, [P|Rest]);

make_patch([{equal, Data}=D|T], PrePatchText, PostPatchText, Count1, Count2, [Patch|Rest]) ->
    Diffs = Patch#patch.diffs,
    Size = size(Data),

    case Size >= 2 * ?PATCH_MARGIN of
        true ->
            case Diffs of
                [] ->
                    throw(not_yet);
                _ ->
                    % Time for a new patch.
                    throw(not_yet)
            end;
        false ->
            throw(not_yet)
    end,

    L1 = Patch#patch.length1 + Size,
    L2 = Patch#patch.length2 + Size,
    
    P = Patch#patch{diffs=Diffs, length1=L1, length2=L2},
        
    make_patch(T, PrePatchText, PostPatchText, Count1+Size, Count2+Size, [P|Rest]).

%%
add_context(Patch, <<>>) ->
    %% Nothing to add.
    Patch;
add_context(Patch, Text) ->
    Diffs = Patch#patch.diffs,
    
    Start = Patch#patch.start2,
    Length = Patch#patch.length1,

    <<_:Start/binary, Pattern:Length/binary, _/binary>> = Text,

    {Prefix, Suffix} = match_padding(Pattern, Text, Start, Length, text_size(Pattern)),

    %% Add the suffix to the list of patches.
    Patch1 = case Suffix of
        <<>> -> Patch;
        _ -> Patch#patch{diffs=[{equal, Suffix}|Diffs]}
    end,

    %% Roll back start and end points.

    %% Extend the length (in bytes) of the patch.

    throw(not_yet).


match_padding(Pattern, Text, Start, BinLength, Utf8Length) ->
    case unique_match(Pattern, Text) of
        true ->
            {<<>>, <<>>}; %% No padding was needed, we already have a unique pattern
        false ->
            %% increase the size of the pattern
            throw(not_yet)
    end.    
    
%%
unique_match(Pattern, Text) ->
    TextSize = size(Text),
    case binary:match(Text, Pattern) of
        nomatch -> 
            error(nomatch);
        {Start, Length} when Start + 1 + Length < TextSize ->
            %% We have a match, and we can search..
            case binary:match(Text, Pattern, [{scope, {Start+1, TextSize-Start-1}}]) of
                nomatch -> true;
                {_, _} -> false
            end;
        {_, _} ->
            true
    end.


%%
%% Helpers
%%

% @doc Return true iff A is a prefix of B
is_prefix(<<>>, B) ->
    true;
is_prefix(A, B) when size(A) > size(B) ->
    false;
is_prefix(<<C1/utf8, ARest/binary>>, <<C2/utf8, BRest/binary>>) when C1 =:= C2 ->
    is_prefix(ARest, BRest);
is_prefix(_, _) ->
    false.

% @doc Return true iff A is a suffix of B
is_suffix(A, B) when size(A) > size(B) ->
    false;
is_suffix(A, B) ->
    size(A) =:= binary:longest_common_suffix([A, B]).


match_front(X1, Y1, A, M, B, N) when X1 < M andalso Y1 < N ->
    case array:get(X1, A) =:= array:get(Y1, B) of
        true -> match_front(X1+1, Y1+1, A, M, B, N);
        false -> {X1, Y1}
    end;
match_front(X1, Y1, _, _, _, _) ->
    {X1, Y1}.

match_reverse(X1, Y1, A, M, B, N) when X1 < M andalso Y1 < N ->
    case array:get(M-X1-1, A) =:= array:get(N-Y1-1, B) of
        true -> match_reverse(X1+1, Y1+1, A, M, B, N);
        false -> {X1, Y1}
    end;
match_reverse(X1, Y1, _, _, _, _) ->
    {X1, Y1}.


%% Implementation of the for statement
for(From, To, Fun, State) ->
    for(From, To, 1, Fun, State).

for(From, To, _Step, _Fun, State) when From >= To ->
    State;
for(From, To, Step, Fun, State) ->
    case Fun(From, State) of
        {continue, S1} -> 
            for(From + Step, To, Step, Fun, S1);
        {break, S1} ->
            S1
    end.
        
split_pre_and_suffix(Text1, Text2) ->
    Prefix = common_prefix(Text1, Text2),
    Suffix = common_suffix(Text1, Text2),
    MiddleText1 = binary:part(Text1, size(Prefix), size(Text1) - size(Prefix) - size(Suffix)), 
    MiddleText2 = binary:part(Text2, size(Prefix), size(Text2) - size(Prefix) - size(Suffix)), 
    {Prefix, MiddleText1, MiddleText2, Suffix}.

    
% @doc Return the common prefix of Text1 and Text2. (utf8 aware)
common_prefix(Text1, Text2) ->
    common_prefix(Text1, Text2, <<>>).

common_prefix(<<C/utf8, Rest1/binary>>, <<C/utf8, Rest2/binary>>, Acc) ->
    common_prefix(Rest1, Rest2, <<Acc/binary, C/utf8>>);
common_prefix(_, _, Acc) ->
    Acc.

% @doc Return the common prefix of Text1 and Text2 (utf8 aware)
common_suffix(Text1, Text2) ->
    %% Note that the builtin common suffix is correct for utf8 input.
    Length = binary:longest_common_suffix([Text1, Text2]),
    binary:part(Text1, size(Text1), -Length).


% @doc Count the number of characters in a utf8 binary.
text_size(Text) when is_binary(Text) ->
    text_size(Text, 0).

text_size(<<>>, Count) ->
    Count;
text_size(<<_C/utf8, Rest/binary>>, Count) ->
    text_size(Rest, Count+1);
text_size(_, _) ->
    error(badarg).

%%
%% Array utilities
%%

% @doc Create an array from a utf8 binary.
array_from_binary(Bin) when is_binary(Bin) ->
    array_from_binary(Bin, 0, array:new()).

array_from_binary(<<>>, _N, Array) ->
    array:fix(Array);
array_from_binary(<<C/utf8, Rest/binary>>, N, Array) ->
    array_from_binary(Rest, N+1, array:set(N, C, Array)).

% @doc Create a binary from an array containing unicode characters.
binary_from_array(Start, End, Array) ->
    binary_from_array(Start, End, Array, <<>>).
    
binary_from_array(N, End, Array, Acc) when N < End ->
    C = array:get(N, Array),
    binary_from_array(N+1, End, Array, <<Acc/binary, C/utf8>>);
binary_from_array(_, _, _, Acc) ->
    Acc.


%%
%% Tests
%%

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

for_test() ->
    ?assertEqual(9, for(0, 10, fun(I, _N) -> {continue, I} end, undefined)),
    ?assertEqual(0, for(0, 10, fun(I, _N) -> {break, I} end, undefined)),
    ok.

array_test() ->
    ?assertEqual(20, array:size(array_from_binary(<<"de apen eten bananen">>))),
    ?assertEqual(<<"broodje aap">>, binary_from_array(0, 11, array_from_binary(<<"broodje aap">>))),
    ?assertEqual(<<"aa">>, binary_from_array(0, 2, array_from_binary(<<"aap">>))),
    ?assertEqual(<<"ap">>, binary_from_array(1, 3, array_from_binary(<<"aap">>))),
    ok.

diff_utf8_test() ->
    ?assertEqual([{equal, <<208,174, 208,189, 208,184, 208,186, 208,190, 208,180>>}], 
        diff(<<208,174,208,189,208,184,208,186,208,190,208,180>>, 
	     <<208,174,208,189,208,184,208,186,208,190,208,180>>)),

    ?assertEqual([{insert, <<208,174,208,189,208,184,208,186,208,190,208,180>>}], 
        diff(<<>>, <<208,174,208,189,208,184,208,186,208,190,208,180>>)),
    ?assertEqual([{delete, <<208,174,208,189,208,184,208,186,208,190,208,180>>}], 
        diff(<<208,174,208,189,208,184,208,186,208,190,208,180>>, <<>>)),

    ?assertEqual([{equal, <<229/utf8>>},
                  {delete, <<228/utf8>>},
                  {equal, <<246/utf8, 251/utf8>>}], 
         diff(<<229/utf8, 228/utf8, 246/utf8, 251/utf8>>, 
              <<229/utf8, 246/utf8, 251/utf8>>)),

    ok.

diff_bisect_test() ->
    ?assertEqual([{equal,<<"fruit flies ">>},
                  {delete,<<"lik">>},
                  {equal,<<"e">>},
                  {insert,<<"at">>},
                  {equal,<<" a banana">>}], diff_bisect(<<"fruit flies like a banana">>, 
        <<"fruit flies eat a banana">>)),
    ok.

common_prefix_test() ->
    ?assertEqual(<<>>, common_prefix(<<"Text">>, <<"Next">>)),
    ?assertEqual(<<"T">>, common_prefix(<<"Text">>, <<"Tax">>)),
    ok.

common_suffix_test() ->
    ?assertEqual(<<"ext">>, common_suffix(<<"Text">>, <<"Next">>)),
    ?assertEqual(<<>>, common_suffix(<<"Text">>, <<"Tax">>)),
    ok.

split_pre_and_suffix_test() ->
    ?assertEqual({<<>>, <<>>, <<>>, <<>>}, split_pre_and_suffix(<<>>, <<>>)),

    ?assertEqual({<<>>, <<"a">>, <<"b">>, <<>>}, split_pre_and_suffix(<<"a">>, <<"b">>)),
    
    ?assertEqual({<<"a">>, <<"b">>, <<"c">>, <<"d">>}, 
       split_pre_and_suffix(<<"abd">>, <<"acd">>)),
    ?assertEqual({<<"aa">>, <<"bb">>, <<"cc">>, <<"dd">>}, 
       split_pre_and_suffix(<<"aabbdd">>, <<"aaccdd">>)),
    ?assertEqual({<<"aa">>, <<"bb">>, <<"c">>, <<"dd">>}, 
       split_pre_and_suffix(<<"aabbdd">>, <<"aacdd">>)),
    ok. 

unique_match_test() ->
    ?assertEqual(true, unique_match(<<"a">>, <<"abc">>)),
    ?assertEqual(true, unique_match(<<"b">>, <<"abc">>)),
    ?assertEqual(true, unique_match(<<"c">>, <<"abc">>)),
    ?assertEqual(false, unique_match(<<"ab">>, <<"abab">>)),
    ok.

text_smaller_than_test() ->
    ?assertEqual(true, text_smaller_than(<<>>, 5)),
    ?assertEqual(true, text_smaller_than(<<>>, 1)),

    ?assertEqual(false, text_smaller_than(<<>>, 0)),

    ?assertEqual(false, text_smaller_than(<<"abc">>, 0)),
    ?assertEqual(false, text_smaller_than(<<"abc">>, 1)),
    ?assertEqual(true, text_smaller_than(<<"abc">>, 4)),

    %% Test if we count characters.
    Utf8Binary = <<1046/utf8, 1011/utf8, 1022/utf8, 127/utf8>>,
    ?assertEqual(true, size(Utf8Binary) > 5), % binary is larger due to utf8 encoding
    ?assertEqual(true, text_smaller_than(Utf8Binary, 5)),
    ?assertEqual(false, text_smaller_than(Utf8Binary, 4)),

    %% Test illegal utf8 sequence, the chars are counted as normal chars
    ?assertEqual(false, text_smaller_than(<<149,157,112,8>>, 4)),

    ok.


-endif.
