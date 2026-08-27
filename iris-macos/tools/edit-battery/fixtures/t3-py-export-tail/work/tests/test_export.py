import unittest

from app.export import export_csv, format_entry, header_line

ENTRIES = [
    {"timestamp": "2026-01-0%d" % n, "actor": "ana", "action": "login", "target": "web"}
    for n in range(1, 5)
]


class ExportTests(unittest.TestCase):
    def test_header(self):
        self.assertEqual(header_line(), "timestamp,actor,action,target")

    def test_one_entry_renders(self):
        self.assertEqual(
            format_entry(ENTRIES[0]), "2026-01-01,ana,login,web"
        )

    def test_escapes_commas_and_quotes(self):
        entry = {"timestamp": "t", "actor": 'a,b', "action": 'say "hi"', "target": None}
        self.assertEqual(format_entry(entry), 't,"a,b","say ""hi""",')

    def test_exact_multiple_of_the_page_size(self):
        document = export_csv(ENTRIES, size=2)
        self.assertEqual(document.split("\n")[0], header_line())
        self.assertEqual(len(document.split("\n")) - 1, 4)

    def test_empty_export_is_just_the_header(self):
        self.assertEqual(export_csv([], size=2), header_line())


if __name__ == "__main__":
    unittest.main()
