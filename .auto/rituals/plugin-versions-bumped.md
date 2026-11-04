---
when: every morning, check that every plugin's version was bumped
schedule: daily 09:00
check: versions-bumped
why: merged code under an unchanged version reaches nobody, so a missing bump has to be caught the day it lands
---
Steps:
- note which plugins the check found unbumped and which merged change touched them
Offers:
- ask Shawn whether to bump the version of each unbumped plugin now
