"""Reading and writing one CSV record.

Dialect (RFC 4180, single-line records):

* Fields are separated by commas.
* A field may be wrapped in double quotes; inside those quotes a comma is an
  ordinary character.
* Inside a quoted field a literal double quote is written as two double
  quotes (``""``). That is the only escape the dialect has.
* An unquoted field is taken literally.

``format_row`` is the inverse of ``parse_row``: for every list of strings,
``parse_row(format_row(fields)) == fields``.
"""

_QUOTE = '"'
_COMMA = ","


def parse_row(line):
    """Split one CSV record into its fields.

    :param line: a single record, without its trailing newline.
    :returns: a list of field strings. A record always has at least one
        field, so ``parse_row("")`` is ``[""]``.
    """
    if not isinstance(line, str):
        raise TypeError("parse_row expects a string")

    fields = []
    buf = []
    index = 0
    length = len(line)
    inside_quotes = False

    while index < length:
        char = line[index]

        if inside_quotes:
            if char == _QUOTE:
                inside_quotes = False
                index += 1
                continue
            buf.append(char)
            index += 1
            continue

        if char == _QUOTE:
            inside_quotes = True
            index += 1
            continue

        if char == _COMMA:
            fields.append("".join(buf))
            buf = []
            index += 1
            continue

        buf.append(char)
        index += 1

    fields.append("".join(buf))
    return fields


def _needs_quoting(field):
    return _COMMA in field or _QUOTE in field or "\n" in field or "\r" in field


def format_row(fields):
    """Render a list of strings as one CSV record.

    A field is quoted only when it has to be, and any double quote inside a
    quoted field is doubled.
    """
    if isinstance(fields, str):
        raise TypeError("format_row expects a sequence of strings, not a string")

    rendered = []
    for field in fields:
        if not isinstance(field, str):
            raise TypeError("format_row expects a sequence of strings")
        if _needs_quoting(field):
            rendered.append(_QUOTE + field.replace(_QUOTE, _QUOTE * 2) + _QUOTE)
        else:
            rendered.append(field)
    return _COMMA.join(rendered)
