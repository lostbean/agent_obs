# Resolve runtime configuration semantics

Status: ready-for-human
Category: bug

- The public API describes `configure/1` as runtime configuration for handlers, the event prefix, and enablement.
- The implementation updates application environment values but does not restart attached handlers. A changed prefix can therefore move emitters away from existing handler subscriptions, and `enabled: false` does not stop helper emission.
- Decide whether runtime reconfiguration restarts handlers, affects only future application starts, or has narrower documented scope.

## Comments
