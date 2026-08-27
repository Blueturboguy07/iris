# calckit

The integer expression evaluator behind the report builder's formula fields.
No dependencies; the whole thing is tokenizer -> parser -> evaluator.

## Build

    cargo build --offline --quiet

## Test

    cargo test --offline --quiet

## Grammar

    expr   := term  (("+" | "-") term)*      left associative
    term   := factor (("*" | "/") factor)*   left associative
    factor := INT | "-" factor | "(" expr ")"

`*` and `/` bind tighter than `+` and `-`. Integer division truncates
toward zero. Everything is `i64`; overflow is an error, not a wrap.
