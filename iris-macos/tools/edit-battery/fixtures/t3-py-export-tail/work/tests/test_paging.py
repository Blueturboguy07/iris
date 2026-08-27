import unittest

from app.paging import page_count, paginate


class PaginateTests(unittest.TestCase):
    def test_splits_an_exact_multiple(self):
        self.assertEqual(paginate([1, 2, 3, 4, 5, 6], 3), [[1, 2, 3], [4, 5, 6]])

    def test_one_full_page(self):
        self.assertEqual(paginate([1, 2, 3], 3), [[1, 2, 3]])

    def test_empty_sequence_has_no_pages(self):
        self.assertEqual(paginate([], 3), [])

    def test_page_size_of_one(self):
        self.assertEqual(paginate([1, 2, 3], 1), [[1], [2], [3]])

    def test_rejects_a_bad_size(self):
        for bad in (0, -1, 2.5, "3", True):
            with self.subTest(size=bad):
                with self.assertRaises(ValueError):
                    paginate([1, 2, 3], bad)

    def test_page_count_matches(self):
        self.assertEqual(page_count([1, 2, 3, 4], 2), 2)
        self.assertEqual(page_count([], 2), 0)


if __name__ == "__main__":
    unittest.main()
