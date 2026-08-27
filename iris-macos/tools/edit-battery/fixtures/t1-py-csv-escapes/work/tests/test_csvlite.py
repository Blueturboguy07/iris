import unittest

from app.csvlite import format_row, parse_row


class ParseRowTests(unittest.TestCase):
    def test_plain_fields(self):
        self.assertEqual(parse_row("a,b,c"), ["a", "b", "c"])

    def test_empty_record_is_one_empty_field(self):
        self.assertEqual(parse_row(""), [""])

    def test_empty_fields_are_preserved(self):
        self.assertEqual(parse_row("a,,c"), ["a", "", "c"])
        self.assertEqual(parse_row(",a,"), ["", "a", ""])

    def test_quoted_field_may_contain_a_comma(self):
        self.assertEqual(parse_row('"x,y",z'), ["x,y", "z"])

    def test_quoted_empty_field(self):
        self.assertEqual(parse_row('"",a'), ["", "a"])

    def test_rejects_non_strings(self):
        with self.assertRaises(TypeError):
            parse_row(None)


class FormatRowTests(unittest.TestCase):
    def test_plain_fields_are_not_quoted(self):
        self.assertEqual(format_row(["a", "b"]), "a,b")

    def test_field_with_a_comma_is_quoted(self):
        self.assertEqual(format_row(["x,y", "z"]), '"x,y",z')

    def test_field_with_a_quote_is_quoted_and_doubled(self):
        self.assertEqual(format_row(['he said "hi"']), '"he said ""hi"""')

    def test_rejects_a_bare_string(self):
        with self.assertRaises(TypeError):
            format_row("abc")


if __name__ == "__main__":
    unittest.main()
