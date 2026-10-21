# forexbot

A gold (XAUUSD) trend-flip bot for MT4 with these risk rules:

- every position gets a hard stop loss
- position size comes from the risk you choose
- a daily loss limit
- scale-in and step-trailing stops

## What's here

| Path | What it is |
|---|---|
| `mt4/XAUUSD_TrendScaler.mq4` | The MT4 bot. Works on its own (LOCAL mode) or with the server (SERVER mode). |
| `tradingview/trend_flip_signal.pine` | The same signal for TradingView. It sends a webhook to the server. |
| `server/` | Optional signal server. It holds the latest TradingView signal, drops old ones and blocks trading around high-impact USD news. |
| `deploy/` | systemd service, Caddy (HTTPS) config and an env template for an Ubuntu VPS. |

## The strategy

On each closed 1-hour bar, the bot compares the close with the close 3 bars earlier. When that direction **flips** (down → up or up → down), it opens a position with a $10 stop. If price moves $3 in your favour and every open position is in profit, it adds another, up to 3. Once a position can lock in $0.50 of profit, its stop trails up in $3 steps.

**This rule has not been shown to make money.** Do step 1 before anything else.

## Step 1: Backtest (no server needed)

1. Copy `mt4/XAUUSD_TrendScaler.mq4` into MT4's `MQL4/Experts` folder (File → Open Data Folder) and compile it in MetaEditor.
2. Strategy Tester: XAUUSD, model **Every tick**, **at least 2 years**, `SignalSource = LOCAL`.
3. Look at:
   - **Number of trades:** you need 100 or more before the result means anything.
   - **Profit factor:** below 1.2 means no real edge once costs are counted.
   - **Max drawdown:** could you live through that with real money?
   - **Out-of-sample check:** tune the settings on 2023–2024 only, then run 2025 unchanged. If 2025 collapses, the settings were fitted to noise.
4. If it fails, stop. Change the idea, not the plumbing.

## Step 2: Demo account for at least 1 month

Attach the bot to an XAUUSD chart on a **demo** account, in LOCAL mode. Make sure it trades the way the backtest did.

## Position size and minimum balance

Each position risks `RiskPercentPerStack / MaxPositions` of the balance. With the defaults (1% risk, 3 positions, $10 stop), one 0.01 lot of gold (usually 100 oz) loses $10 at the stop. That means:

- **About $3,000 is the smallest balance that can trade the defaults.**
- Below that, the bot skips trades and says why in the Experts log.

That is the point. Don't raise the risk to make it trade. Use `MaxPositions = 1` or a smaller stop instead.

## Step 3 (optional): Signal server

You only need this for TradingView signals or the news filter. LOCAL mode doesn't use it.

You need an Ubuntu VPS and a domain name pointing at it. A free DuckDNS subdomain is fine. TradingView only sends webhooks to ports 80 and 443, and MT4 needs a valid HTTPS certificate.

```bash
sudo apt update && sudo apt install -y python3-venv git caddy
sudo useradd --system --home /opt/forexbot forexbot
sudo git clone https://github.com/jackiec7786/forexbot /opt/forexbot
sudo python3 -m venv /opt/forexbot/venv
sudo /opt/forexbot/venv/bin/pip install -r /opt/forexbot/server/requirements.txt
sudo mkdir -p /opt/forexbot/state && sudo chown forexbot /opt/forexbot/state

sudo cp /opt/forexbot/deploy/forexbot.env.example /etc/forexbot.env
openssl rand -hex 24            # paste this as SIGNAL_SECRET in /etc/forexbot.env
sudo nano /etc/forexbot.env
sudo chmod 600 /etc/forexbot.env

sudo cp /opt/forexbot/deploy/signal-server.service /etc/systemd/system/
sudo systemctl enable --now signal-server
sudo cp /opt/forexbot/deploy/Caddyfile /etc/caddy/Caddyfile   # set your domain first
sudo systemctl reload caddy

curl https://YOUR_DOMAIN/health   # should print {"ok":true}
```

Update later with: `cd /opt/forexbot && sudo git pull && sudo systemctl restart signal-server`

**TradingView:** add the Pine script to a 1-hour XAUUSD chart and set the secret in its settings. Create an alert with condition **"Any alert() function call"** and webhook URL `https://YOUR_DOMAIN/webhook/tradingview`.

**MT4:** go to Tools → Options → Expert Advisors, tick "Allow WebRequest" and add `https://YOUR_DOMAIN`. Then set `SignalSource = SERVER`, `ServerUrl = https://YOUR_DOMAIN/api/signal` and `ServerSecret` to the same secret.

**Debugging:** `curl -H "X-Signal-Secret: YOUR_SECRET" https://YOUR_DOMAIN/api/status` shows the current answer and why.

### How the server decides

- Only `BUY` and `SELL` alerts are accepted, and only with the right secret.
- A signal older than 15 minutes is ignored, so there are no late entries.
- It blocks trading 30 minutes before and after high-impact USD news, using the Forex Factory calendar.
- If the calendar can't be loaded, it blocks trading. It fails safe.
- Each signal has an ID, so MT4 trades it once at most, even after a restart.

## Running the server tests

```bash
cd server
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt -r requirements-dev.txt
.venv/bin/pytest
```

## Changes from the earlier draft

- **Hard stop loss on every position.** Before, a losing trade had no stop. If a broker rejects a stop on a market order, the bot attaches it right after opening, or closes the trade.
- **Sizing from risk.** The old `balance / 100 × 0.04` put 40% of the account at risk on a $10 move.
- **Daily loss limit** instead of a 25% session target. It survives restarts.
- **No AI gatekeeper.** A plain GPT call can't see the news, the old OpenAI code crashed on current versions, and it was slower than MT4's 1-second timeout. A news calendar does the job reliably.
- **No cTrader.** It ran the same rule on the same prices, so it never confirmed anything.
- **Signals have an ID and an age limit.** No re-entering on yesterday's signal.
- **Server security:** HTTPS, the secret comes from an environment variable and travels in a header, and the server runs as a normal user, not root.
