"""The paged search API.

Callers ask for one page at a time; page numbers are 1-based.
"""

from .paging import DEFAULT_PAGE_SIZE, paginate


def matching(entries, needle):
    """Entries whose ``message`` contains ``needle``, in original order."""
    return [entry for entry in entries if needle in entry.get("message", "")]


def page_of_results(entries, needle, page=1, size=DEFAULT_PAGE_SIZE):
    """One 1-based page of the entries matching ``needle``.

    Returns ``[]`` for a page number past the end of the results.
    """
    if not isinstance(page, int) or isinstance(page, bool) or page < 1:
        raise ValueError("page must be an integer >= 1")

    pages = paginate(matching(entries, needle), size)
    if page > len(pages):
        return []
    return pages[page - 1]
