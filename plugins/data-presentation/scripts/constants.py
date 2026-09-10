"""Every tuned number the skill depends on, in one place.

Selection and rendering both read these. A restated constant is what a mutation sweep
half-covers, which is why they do not live next to their call sites.
"""

# --- Presentation selection -------------------------------------------------

# Below this a table shows every exact value in comparable vertical space and loses
# nothing. A chart earns its place by showing shape, not by being smaller.
MIN_CHART_POINTS = 8

# Series are indistinguishable without colour, and colour is unavailable: the renderer
# reads its glyph set once, outside the per-series loop, and varies only colour per
# series. Colour is raw ANSI, which is literal garbage inside a fenced block.
MAX_SERIES_PER_CHART = 1

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
