# AppSwitcherPanel

The floating panel UI. Built fresh on every open, torn down on hide.

## Layout

Two sections drawn from the same items, stacked vertically with a thin divider:

```
main       recent apps/windows        always shown
--------   divider
secondary  older apps/windows          faded + smaller; toggled with T
```

- **Horizontal** (app switcher): a grid of bare icon tiles, packed
  `itemsPerRow` wide. Icons scale to the target screen's height.
- **Vertical** (window switcher): a single column of `[icon] [name]` rows.

## Invariants

- The selection is a `(row, column)` into `rows`. Navigation wraps and only
  reaches `navigableRowCount` rows (main-only until the secondary is toggled on).
- `appendItems` adds live-launched apps to the end of the **main** section
  (before the divider); `removeSelectedItem` drops a tile and re-flows.
- A resize keeps the **top** edge fixed (horizontal) or the **center** fixed
  (vertical list, which could otherwise grow off-screen).

## Click-away & hover

- The event tap is `.listenOnly` and can't consume clicks, so per-screen
  `ClickShieldPanel`s sit one window level below and catch outside clicks,
  reporting a dismiss.
- Hover selection has a dead zone (mouse must move a few px before it takes
  over) and is briefly suppressed around mid-open resizes, which can emit
  spurious `mouseEntered`.
