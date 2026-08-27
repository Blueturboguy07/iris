# csvlite

A dependency-free reader/writer for the one CSV dialect we care about
(RFC 4180, single-line records).

## Build

    python3 -m compileall -q app

## Test

    python3 -m unittest discover -s tests -t .

## Dialect

* Fields are separated by commas.
* A field MAY be wrapped in double quotes. Inside a quoted field a comma is
  an ordinary character.
* Inside a quoted field, a literal double quote is written as two double
  quotes (`""`). This is the only escape in the dialect.
* An unquoted field is taken literally.

`format_row` is the inverse of `parse_row`: for any list of strings,
`parse_row(format_row(fields)) == fields`.
