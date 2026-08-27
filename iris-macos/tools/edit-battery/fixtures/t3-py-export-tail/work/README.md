# auditkit

The audit-log service: pageable search, and a CSV export for compliance.

## Build

    python3 -m compileall -q app

## Test

    python3 -m unittest discover -s tests -t .

## Layout

    app/paging.py    shared paging helper, used by both features below
    app/search.py    the paged search API
    app/export.py    the compliance CSV export
