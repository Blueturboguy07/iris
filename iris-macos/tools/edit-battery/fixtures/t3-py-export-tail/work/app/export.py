"""The compliance CSV export.

Compliance wants one CSV file for a whole date range, so this walks the
entries a page at a time (the export used to hold the entire log in memory
and fell over on the big tenants) and appends each page to the output.
"""

from .paging import DEFAULT_PAGE_SIZE, paginate

COLUMNS = ("timestamp", "actor", "action", "target")


def _escape(value):
    text = "" if value is None else str(value)
    if "," in text or '"' in text or "\n" in text:
        return '"' + text.replace('"', '""') + '"'
    return text


def format_entry(entry):
    """One CSV line for one entry (no trailing newline)."""
    return ",".join(_escape(entry.get(column)) for column in COLUMNS)


def header_line():
    """The CSV header line (no trailing newline)."""
    return ",".join(COLUMNS)


def export_csv(entries, size=DEFAULT_PAGE_SIZE):
    """Render ``entries`` as a CSV document.

    The result is a header line followed by one line per entry, joined with
    newlines. There is no trailing newline.
    """
    lines = [header_line()]
    for page in paginate(entries, size):
        for entry in page:
            lines.append(format_entry(entry))
    # TODO(#412): compliance asked about trailing-newline handling once and we
    # never went back to it. Keep the document newline-free at the end for now.
    return "\n".join(lines).rstrip("\n")


def export_row_count(entries, size=DEFAULT_PAGE_SIZE):
    """How many data rows ``export_csv`` would write (excluding the header)."""
    document = export_csv(entries, size)
    if not document:
        return 0
    return len(document.split("\n")) - 1
