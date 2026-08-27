"""Held-out oracle for t1-py-csv-escapes.

Dropped into a pristine copy of the repo at grade time. The agent never sees
this file. Run with:

    python3 -m unittest oracle_test -v

F2P (must go red -> green): DoubledQuoteEscape, RoundTrip.
P2P (must stay green):      Regression.
"""

import unittest

from app.csvlite import format_row, parse_row


class DoubledQuoteEscape(unittest.TestCase):
    """The one escape the dialect has. Red on the shipped code."""

    def test_doubled_quote_inside_a_quoted_field(self):
        self.assertEqual(parse_row('a,"b""c",d'), ["a", 'b"c', "d"])

    def test_field_that_is_only_a_quote(self):
        self.assertEqual(parse_row('""""'), ['"'])

    def test_quotes_around_and_inside(self):
        self.assertEqual(parse_row('"""x"""'), ['"x"'])

    def test_sentence_with_an_inner_quotation(self):
        self.assertEqual(
            parse_row('"he said ""hi"", loudly",x'),
            ['he said "hi", loudly', "x"],
        )

    def test_doubled_quote_next_to_a_comma_inside_quotes(self):
        self.assertEqual(parse_row('"a"",""b"'), ['a","b'])

    def test_trailing_doubled_quote(self):
        self.assertEqual(parse_row('"ab"""'), ['ab"'])

    def test_leading_doubled_quote(self):
        self.assertEqual(parse_row('"""ab"'), ['"ab'])

    def test_many_doubled_quotes(self):
        self.assertEqual(parse_row('"""""""""'), ['""""'])


def _lcg(seed):
    state = seed
    while True:
        state = (state * 6364136223846793005 + 1442695040888963407) % (2 ** 64)
        yield (state >> 33) % (2 ** 31)


class RoundTrip(unittest.TestCase):
    """format_row is documented as the inverse of parse_row.

    A hardcoded special case for one input cannot survive this: the field
    lists are generated, not listed.
    """

    ALPHABET = ['x', 'y', '"', ',', '', ' ', '\n', 'z"', '"', ',,']

    def test_documented_examples_round_trip(self):
        for fields in (
            ["a", "b", "c"],
            [""],
            ["", ""],
            ['"'],
            ['a"b'],
            ['a"b,c', "d"],
            ['he said "hi"'],
            ["multi\nline", "x"],
            ['"quoted"', ",", '""'],
        ):
            with self.subTest(fields=fields):
                self.assertEqual(parse_row(format_row(fields)), fields)

    def test_generated_field_lists_round_trip(self):
        rng = _lcg(20260826)
        checked = 0
        for _ in range(400):
            width = 1 + next(rng) % 4
            fields = []
            for _ in range(width):
                pieces = next(rng) % 4
                fields.append(
                    "".join(self.ALPHABET[next(rng) % len(self.ALPHABET)]
                            for _ in range(pieces))
                )
            rendered = format_row(fields)
            self.assertEqual(
                parse_row(rendered), fields,
                "round trip failed for %r (rendered as %r)" % (fields, rendered),
            )
            checked += 1
        self.assertEqual(checked, 400)


class Regression(unittest.TestCase):
    """Green before the fix and after it. A fix that breaks these fails."""

    def test_plain_fields(self):
        self.assertEqual(parse_row("a,b,c"), ["a", "b", "c"])

    def test_empty_record(self):
        self.assertEqual(parse_row(""), [""])

    def test_empty_fields(self):
        self.assertEqual(parse_row("a,,c"), ["a", "", "c"])
        self.assertEqual(parse_row(",a,"), ["", "a", ""])

    def test_comma_inside_quotes(self):
        self.assertEqual(parse_row('"x,y",z'), ["x,y", "z"])

    def test_quoted_empty_field(self):
        self.assertEqual(parse_row('"",a'), ["", "a"])

    def test_unquoted_is_literal(self):
        self.assertEqual(parse_row("a b,c d"), ["a b", "c d"])

    def test_parse_row_type_check(self):
        with self.assertRaises(TypeError):
            parse_row(None)

    def test_format_row_quoting_rules(self):
        self.assertEqual(format_row(["a", "b"]), "a,b")
        self.assertEqual(format_row(["x,y", "z"]), '"x,y",z')
        self.assertEqual(format_row(['he said "hi"']), '"he said ""hi"""')

    def test_format_row_type_check(self):
        with self.assertRaises(TypeError):
            format_row("abc")


if __name__ == "__main__":
    unittest.main()
