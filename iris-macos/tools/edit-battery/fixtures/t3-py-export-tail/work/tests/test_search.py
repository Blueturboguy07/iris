import unittest

from app.search import matching, page_of_results

ENTRIES = [
    {"message": "login ok", "actor": "ana"},
    {"message": "login failed", "actor": "bo"},
    {"message": "login ok", "actor": "cy"},
    {"message": "logout", "actor": "di"},
    {"message": "login ok", "actor": "ed"},
    {"message": "login ok", "actor": "fay"},
]


class SearchTests(unittest.TestCase):
    def test_matching_filters_in_order(self):
        actors = [entry["actor"] for entry in matching(ENTRIES, "login ok")]
        self.assertEqual(actors, ["ana", "cy", "ed", "fay"])

    def test_first_page(self):
        page = page_of_results(ENTRIES, "login ok", page=1, size=2)
        self.assertEqual([entry["actor"] for entry in page], ["ana", "cy"])

    def test_second_page(self):
        page = page_of_results(ENTRIES, "login ok", page=2, size=2)
        self.assertEqual([entry["actor"] for entry in page], ["ed", "fay"])

    def test_page_past_the_end_is_empty(self):
        self.assertEqual(page_of_results(ENTRIES, "login ok", page=9, size=2), [])

    def test_rejects_a_bad_page_number(self):
        with self.assertRaises(ValueError):
            page_of_results(ENTRIES, "login ok", page=0, size=2)


if __name__ == "__main__":
    unittest.main()
