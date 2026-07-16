# Origin transition state machine

```text
local preflight(target)
  -> stop(previous connector)
  -> confirm previous stopped
  -> start(target connector)
  -> confirm target running and exclusive
  -> bounded public health/catalog/basic probe
       success -> atomic active-origin write
       failure -> stop target -> restore previous -> public probe previous
               -> retain/write previous marker -> return failure
```

The serialized lock and stop confirmation make the connector states mutually
exclusive. A failed public probe never writes the requested target marker.
