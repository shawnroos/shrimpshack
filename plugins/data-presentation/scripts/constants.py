"""Every tuned number the skill depends on, in one place.

Selection and rendering both read these. A restated constant is what a mutation sweep
half-covers, which is why they do not live next to their call sites.
"""

# --- Presentation selection -------------------------------------------------

# Below this a table shows every exact value in comparable vertical space and loses
# nothing. A chart earns its place by showing shape, not by being smaller.
MIN_CHART_POINTS = 8

# One series per chart is structural, not tunable: selection emits one chart per
# eligible series, so there is no constant to move. A pinned MAX_SERIES_PER_CHART = 1
# was removed because nothing read it - the pin protected a number, not the behaviour.

# Beyond three single-series charts a table compares them better.
MAX_STACKED_CHARTS = 3

# --- Budgets ----------------------------------------------------------------

# Fits a narrow chat pane without wrapping, which would destroy the character grid.
# A judgement, not a measurement.
COLUMN_BUDGET = 72

# The renderer defaults its height to the data's numeric interval, so a series spanning
# 0 to 100000 renders 100001 lines unless a height is passed. Never omit it.
CHART_ROW_BUDGET = 12

# Beyond this the table stops being readable in a scrolling transcript.
TABLE_ROW_BUDGET = 40

# Each series is a table column, and columns cannot be narrowed indefinitely. Past this
# the row is wider than the column budget whatever the labels do, so it is refused at
# the gate rather than rendered over budget.
MAX_SERIES = 8

# Where an SI suffix first shortens a significant-digits label rather than lengthening it.
ABBREVIATE_ABOVE = 10000

# Significant digits below the abbreviation threshold. Fixed decimals were rejected:
# two of them render 0.001, 0.002 and 0.003 as three identical cells reading 0.00.
SIGNIFICANT_DIGITS = 4

# --- Caller text ------------------------------------------------------------

# Caller text is escaped and capped so a delimiter, a newline, or a fence cannot break
# the rendered block, and so a long label cannot blow the column budget on its own.
MAX_LABEL_CHARS = 24
MAX_TITLE_CHARS = 120

# A caption is one line inside the block, so its source fields are bounded too.
MAX_SOURCE_FIELDS = 8

# --- Notes ---------------------------------------------------------------------

# A note names this many missing positions and then counts the rest. Enumerating all of
# them put several hundred characters into one note for a series with sixty gaps.
MAX_LISTED_POSITIONS = 6
