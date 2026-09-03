# Decide span-context lifecycle semantics

Status: ready-for-human
Category: bug

- The recovered design requires a completed child span to restore its parent context.
- The Phoenix and Generic handlers keep one process-dictionary entry per event type. A nested operation of the same type overwrites the outer entry, so completing the child can leave the outer span without an active context.
- Handler and Jido callback rescue paths suppress errors, but context restoration is not protected by an `after` block and therefore is not guaranteed when translation, status, or span-ending work raises.
- Decide whether same-type nesting and cleanup after callback failures are required contracts. If they are, change the implementation and add focused regression tests in separate application-behavior work.

## Comments
