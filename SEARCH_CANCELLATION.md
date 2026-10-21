# Search cancellation

Searches run in a subprocess so the UI keeps responding while a mirror is slow. Tap the loading message to cancel and return to the same query. Searches stop after 90 seconds; book downloads stop after 300 seconds. Cancelling also terminates child commands and discards late results.

See `tests/SEARCH_CANCELLATION.md` for the regression tests.
