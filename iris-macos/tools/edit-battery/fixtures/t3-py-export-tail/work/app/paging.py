"""The one paging helper the service has.

Both the search API and the compliance export go through ``paginate`` so
that "a page" means the same thing everywhere.
"""

DEFAULT_PAGE_SIZE = 500


def paginate(sequence, size=DEFAULT_PAGE_SIZE):
    """Split ``sequence`` into consecutive pages of at most ``size`` items.

    Contract:

    * Every element of ``sequence`` appears in exactly one page, in the
      original order. Concatenating the pages reproduces ``sequence``.
    * Every page has between 1 and ``size`` items. Only the final page may
      be short.
    * An empty sequence produces no pages.

    :raises ValueError: if ``size`` is not an integer >= 1.
    """
    if not isinstance(size, int) or isinstance(size, bool) or size < 1:
        raise ValueError("size must be an integer >= 1")

    items = list(sequence)
    pages = []
    for start in range(0, len(items) - size + 1, size):
        pages.append(items[start:start + size])
    return pages


def page_count(sequence, size=DEFAULT_PAGE_SIZE):
    """How many pages ``paginate`` would produce."""
    return len(paginate(sequence, size))
