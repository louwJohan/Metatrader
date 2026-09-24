# RSI Percentage Risk EA

## Files and installation

Copy `RSI_Percent_Risk_EA.mq5` into your MT5 data folder under `MQL5/Experts`, open it in MetaEditor and compile with F7. Attach it to the required symbol in a **hedging account**. The source uses native MQL5 indicator handles, CopyBuffer, position tickets, OrderCheck/OrderSend and the standard MQL5 CTrade library.

**Verification status:** source and API review completed; MetaEditor/MT5 was not available in the build environment. This delivery is source code, not a compiled EX5, and has not undergone a Strategy Tester or broker execution test. Complete the acceptance checks below before deployment.

## Trading rules

- RSI uses PRICE_CLOSE, period 14 and H1 by default. Only completed bars are evaluated, once per new RSI bar. The chart timeframe does not matter unless an input uses PERIOD_CURRENT.
- An armed buy is eligible below 30; an armed sell is eligible above 70. Equality does not qualify. These are level conditions, not a requirement to observe a threshold crossing on two consecutive bars. A fresh installation can therefore enter on its first tick using the latest closed bar.
- Following a submitted buy request, buying remains disarmed until a later closed RSI bar is strictly above 50. Selling rearms strictly below 50. The sides are independent. Existing positions do not have to close before another properly rearmed entry. Optional maximum own positions defaults to unlimited.
- The optional MA filter defaults to off, with SMA(50), D1, PRICE_CLOSE. It compares the executable Ask for buying or Bid for selling against the most recently closed MA bar. It also checks the actual position entry price against the MA bar closed at entry time; an invalid fill is closed by ticket when trading is available. Slippage means no market-order EA can guarantee that an invalid fill never occurs. Closing it incurs the normal spread, costs and execution risk. If MA history is temporarily unavailable, existing broker stops remain and validation retries.
- No opposite-signal exit is used. Positions exit through SL, TP, trailing SL, or the actual-fill MA safeguard.

## Stops and trailing

Default SL is 5% and TP is 1% of entry price. Zero disables that initial stop or target. Initial protection is submitted with the market request using the quote price; management then reconciles it with the actual fill price. Broker tick-size rounding applies. An existing tighter SL is never loosened, so the reconciled stop can be closer than the exact percentage. TP is reconciled to the configured percentage. Requests violating broker stop/freeze rules are skipped rather than widening the configured risk distance.

Trailing defaults: enabled; trigger 0.5%, distance 0.1%, step 0.05%. All three percentages use the individual position's actual opening price, not current price or account balance. Trigger uses Bid for buys and Ask for sells. Activation is latched and persisted. Subsequent SL changes must improve the existing stop by at least the configured step and one price tick. SL never moves backward. Trailing can be used with initial SL=0 in fixed-lot mode.

For a buy at 100, initial SL=95 and TP=101. At Bid=100.50 the trail can set SL=100.40; the next step is eligible at Bid=100.55 with SL=100.45, subject to broker tick/distance rules. Sell behavior is symmetrical.

Position management runs on the first tick of each server second and after deal events. It does not run while MT5 is stopped/disconnected; SL/TP already accepted by the broker remain server-side. No historical trailing high/low is fabricated after downtime.

## Sizing

| Mode | Input | Behavior |
|---|---|---|
| Balance percentage (default) | 1% | Budget = account balance × percentage / 100 |
| Account currency | 100 | Budget in the account's deposit currency |
| Fixed lots | 0.10 | Explicit volume, necessary when initial SL is zero |

Risk modes use OrderCalcProfit to estimate loss from entry to the rounded SL in account currency. Volume is rounded **down**, respects symbol min/max/step and account-wide directional symbol volume limits, and must pass OrderCheck including margin validation. If the budget cannot support the minimum lot, the EA skips the trade. It never silently switches to minimum lots or fixed lots. Risk modes with SL=0 are rejected during initialization.

Risk means estimated price loss at SL; it is not a guaranteed maximum loss. Commission, swaps, slippage, gaps and changing currency conversion are not included. The percentage is per entry, not a portfolio-wide risk cap; multiple positions accumulate exposure. Stops and volumes are symbol-specific; symbols must have valid broker metadata, positive prices, supported market execution, sufficient history and permitted trading conditions.

## Ownership and netting safeguard

Every position modification/close requires both chart symbol and magic number to match, and uses the position ticket. Other strategies' positions/orders are read only when calculating broker-wide volume limits. The EA never cancels pending orders and waits while an order of its own remains active. Use a unique nonzero magic number for this strategy; another EA deliberately using the same symbol/magic cannot be distinguished.

**Netting and exchange-netting accounts are rejected at initialization.** MT5 combines all trades on a symbol into one position in those account types, so magic numbers cannot guarantee strict ownership of the resulting exposure. This implementation chooses strict isolation and does not offer an unsafe netting override. Use a hedging account for this EA.

An exclusive state-file handle prevents two copies using the same account/server/symbol/magic in one terminal. It does not coordinate separate terminal installations or computers. Run only one copy per account/symbol/magic across all terminals.

## Restart recovery

Live state is an append-only binary journal in the terminal's `MQL5/Files` directory. Its name begins `RSIPct_v1_` and contains account login, hashes of server/symbol, and magic. Records hold processed-bar time, independent arming flags and activated position identifiers, with integrity checks. Writes are flushed before sending an entry request. This avoids the four-week expiry of terminal global variables.

- Existing positions, entry prices and broker stops are read from MT5 rather than duplicated in a local position ledger.
- On restart, processed bars are not traded again. Missed closed RSI bars are replayed for **rearming only**; only the latest closed bar can generate a new entry. Unavailable history postpones evaluation.
- A pre-send durable intent consumes that direction's signal, even if the request is rejected or times out. This conservative at-most-once policy can miss a trade after a crash between persistence and sending, but avoids blindly resubmitting an uncertain request. A fresh midline rearm is required.
- If the state file is missing but matching broker history or positions exist, both directions start disarmed. If the journal is damaged, initialization fails; retain it for diagnosis and restore a known-good backup. The EA does not silently discard damaged state. Broker SL/TP remain active, but no EA trailing runs after failed initialization.
- If durable writing fails during operation, new entries stop. Existing stop management continues when possible.
- Moving the EA to another terminal requires moving its journal while the original instance is stopped. Broker history availability limits recovery when the journal has been lost.
- Keep inputs stable while positions are open. Reinitializing with changed inputs keeps the same arming journal but applies the new stop/filter rules to existing owned positions. In particular, enabling/changing the MA can close a position that fails the revised entry-time filter. A different magic starts a separate strategy and will not manage old-magic positions.

Strategy Tester/optimization passes use fresh in-memory state and do not read/write the live journal. All tunable settings are numeric, boolean or enum `input` values. Use a hedging test account configuration. Invalid parameter combinations are rejected with INIT_PARAMETERS_INCORRECT.

## Acceptance checks in MetaTrader 5

1. Compile in current MetaEditor and resolve any diagnostics; no native compilation was possible here.
2. Run "Every tick based on real ticks" on a hedging account with adequate H1/D1 history. Confirm buy sequence 29 → 25 → 50 → 51 → 29 produces two entries, with no extra entry at 25 or rearm at exactly 50. Check the mirrored sell sequence 71 → 75 → 50 → 49 → 71.
3. Enable the MA; verify equality blocks entry, buys require Ask above MA, sells require Bid below MA, and slippage violations close only the corresponding owned ticket.
4. Verify both risk modes on FX, a metal and an index/CFD with different lot steps and account currency. Independently compare OrderCalcProfit loss with the budget. Test a budget below minimum lot and insufficient margin: no order should be sent.
5. Check SL=0 and TP=0 in fixed-lot mode. Verify SL=0 with either risk mode rejects initialization.
6. Test trailing trigger, exact step, retracement, broker minimum/freeze distance and restart after activation. Stops must never loosen. Test a trail distance larger than the trigger, too.
7. Restart in the same RSI bar, while disarmed, after a midline rearm and across missed bars. Confirm no duplicate entry, no historical backfill orders and restoration of existing-position management.
8. Test rejected/uncertain requests, partial fills and active residual orders in a suitable demo environment. The direction must remain disarmed and there must be no automatic uncertain-request retry.
9. Run alongside manual positions, another magic on this symbol and this magic on another symbol. Confirm only matching symbol/magic tickets are modified/closed. Duplicate same-terminal instances must fail their state-file lock. A netting account must reject initialization.
10. Compare repeated identical optimization passes for identical results. Confirm test runs do not alter the live journal.

## API references

- [OrderSend acceptance versus execution](https://www.mql5.com/en/docs/trading/ordersend)
- [OrderCalcProfit and account-currency estimates](https://www.mql5.com/en/docs/trading/ordercalcprofit)
- [Symbol price, volume and execution properties](https://www.mql5.com/en/docs/constants/environment_state/marketinfoconstants)
- [MT5 position accounting: netting and hedging](https://www.metatrader5.com/en/terminal/help/trading/general_concept)
- [FileOpen and terminal file sandbox](https://www.mql5.com/en/docs/files/fileopen)
