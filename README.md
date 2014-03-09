# Diffy

Diff, Match and Patch implementation for Erlang. 

## Introduction

Diffy is an erlang implementation of the Diff Match and Patch library for plain text.  The 
implementation uses binaries throughout and is utf-8 aware.

Example

```erlang

1> diffy:diff(<<"fruit flies like a banana">>, <<"fruit flies eat a banana">>)
[{equal,<<"fruit flies ">>},
 {delete,<<"like">>},
 {insert,<<"eat">>},
 {equal,<<" a banana">>}]
```
## TODO

* cleanup_semantic(diffs()) -> diffs()
* make_patch(Text1, Text2) -> patches(), make_patch(unicode_binary(), diffs()) -> patches(), make_patch(Diffs) -> patches()
* match(Text, Pattern, Loc) 

## References

Much good info about diff, match and patch can found at
link: http://neil.fraser.name/writing/diff/

