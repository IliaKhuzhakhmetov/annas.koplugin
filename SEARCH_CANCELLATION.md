# Search cancellation

Searches run in a subprocess so the UI keeps responding while a mirror is slow. The loading window uses KOReader's native `ProgressbarDialog`. It leaves the bar hidden while the amount of work is unknown. Tap the dialog or press a key to cancel and return to the same query. Searches stop after 90 seconds; book downloads stop after 300 seconds. Cancelling also terminates child commands and discards late results.

See `tests/SEARCH_CANCELLATION.md` for the regression tests.
