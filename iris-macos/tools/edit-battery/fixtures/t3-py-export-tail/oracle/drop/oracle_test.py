"""Held-out oracle for t3-py-export-tail.

Dropped into a pristine copy at grade time; the agent never sees it.
    python3 -m unittest oracle_test -v

F2P classes: ExportKeepsEveryRow, PagingContract, SearchCoversEveryMatch.
P2P classes: Regression.
"""

import unittest

from app.export import export_csv, export_row_count, format_entry, header_line
from app.paging import page_count, paginate
from app.search import matching, page_of_results

SIZES = (1, 2, 3, 4, 5, 7, 10, 500)


def entries(count):
    return [
        {
            "timestamp": "2026-01-%02d" % ((n % 28) + 1),
            "actor": "user%d" % n,
            "action": "login",
            "target": "web",
        }
        for n in range(count)
    ]


class ExportKeepsEveryRow(unittest.TestCase):
    """The reported symptom, swept over every length/page-size pair."""

    def test_row_count_always_equals_entry_count(self):
        for count in range(0, 26):
            for size in SIZES:
                with self.subTest(count=count, size=size):
                    document = export_csv(entries(count), size=size)
                    lines = document.split("\n")
                    self.assertEqual(lines[0], header_line())
                    self.assertEqual(
                        len(lines) - 1 if document else 0, count,
                        "wrong row count for count=%d size=%d" % (count, size),
                    )

    def test_rows_are_in_order_and_complete(self):
        for count in (1, 2, 3, 7, 11, 25):
            for size in SIZES:
                with self.subTest(count=count, size=size):
                    source = entries(count)
                    rows = export_csv(source, size=size).split("\n")[1:]
                    self.assertEqual(rows, [format_entry(e) for e in source])

    def test_export_row_count_helper_agrees(self):
        for count in range(0, 26):
            for size in SIZES:
                with self.subTest(count=count, size=size):
                    self.assertEqual(export_row_count(entries(count), size=size), count)

    def test_a_single_entry_still_exports(self):
        document = export_csv(entries(1), size=500)
        self.assertEqual(len(document.split("\n")), 2)


class PagingContract(unittest.TestCase):
    """paginate's own docstring, taken literally."""

    def test_pages_concatenate_back_to_the_input(self):
        for count in range(0, 40):
            for size in SIZES:
                with self.subTest(count=count, size=size):
                    items = list(range(count))
                    pages = paginate(items, size)
                    flat = [item for page in pages for item in page]
                    self.assertEqual(flat, items)

    def test_page_sizes_are_full_except_possibly_the_last(self):
        for count in range(0, 40):
            for size in SIZES:
                pages = paginate(list(range(count)), size)
                for index, page in enumerate(pages):
                    self.assertTrue(1 <= len(page) <= size)
                    if index < len(pages) - 1:
                        self.assertEqual(len(page), size)

    def test_page_count_matches_paginate(self):
        for count in range(0, 40):
            for size in SIZES:
                expected = (count + size - 1) // size
                self.assertEqual(page_count(list(range(count)), size), expected)

    def test_works_on_a_generator(self):
        self.assertEqual(paginate((n for n in range(5)), 2), [[0, 1], [2, 3], [4]])


class SearchCoversEveryMatch(unittest.TestCase):
    """The other consumer of the same helper."""

    def test_walking_the_pages_yields_every_match(self):
        for count in range(0, 20):
            for size in (1, 2, 3, 7):
                with self.subTest(count=count, size=size):
                    rows = [{"message": "hit %d" % n, "actor": "a%d" % n}
                            for n in range(count)]
                    expected = matching(rows, "hit")
                    seen = []
                    page = 1
                    while True:
                        chunk = page_of_results(rows, "hit", page=page, size=size)
                        if not chunk:
                            break
                        seen.extend(chunk)
                        page += 1
                        self.assertLess(page, 200, "paging did not terminate")
                    self.assertEqual(seen, expected)


class Regression(unittest.TestCase):
    """Green before the fix; a fix that breaks these fails."""

    def test_exact_multiples_unchanged(self):
        self.assertEqual(paginate([1, 2, 3, 4, 5, 6], 3), [[1, 2, 3], [4, 5, 6]])
        self.assertEqual(paginate([1, 2, 3], 3), [[1, 2, 3]])
        self.assertEqual(paginate([1, 2, 3], 1), [[1], [2], [3]])
        self.assertEqual(paginate([], 3), [])

    def test_bad_page_size_still_raises(self):
        for bad in (0, -1, 2.5, "3", True, None):
            with self.subTest(size=bad):
                with self.assertRaises(ValueError):
                    paginate([1, 2, 3], bad)

    def test_bad_page_number_still_raises(self):
        with self.assertRaises(ValueError):
            page_of_results([], "x", page=0, size=2)
        with self.assertRaises(ValueError):
            page_of_results([], "x", page=True, size=2)

    def test_page_past_the_end_is_empty(self):
        rows = [{"message": "hit", "actor": "a"}]
        self.assertEqual(page_of_results(rows, "hit", page=9, size=2), [])

    def test_csv_escaping_unchanged(self):
        entry = {"timestamp": "t", "actor": "a,b", "action": 'say "hi"', "target": None}
        self.assertEqual(format_entry(entry), 't,"a,b","say ""hi""",')

    def test_header_unchanged(self):
        self.assertEqual(header_line(), "timestamp,actor,action,target")

    def test_empty_export_is_just_the_header(self):
        self.assertEqual(export_csv([], size=2), header_line())
        self.assertEqual(export_row_count([], size=2), 0)

    def test_no_trailing_newline(self):
        self.assertFalse(export_csv(entries(3), size=2).endswith("\n"))


if __name__ == "__main__":
    unittest.main()
