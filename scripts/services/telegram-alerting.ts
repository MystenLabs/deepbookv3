import axios from "axios";
import { AlertProvider, AlertEvent, AlertSeverity } from "./alerting.ts";

export interface TelegramAlertConfig {
  botToken: string;
  chatId: string;
  /** Minimum severity to send (default: WARNING) */
  minSeverity?: AlertSeverity;
}

export class TelegramAlertProvider implements AlertProvider {
  private botToken: string;
  private chatId: string;
  private minSeverity: AlertSeverity;

  constructor(config: TelegramAlertConfig) {
    this.botToken = config.botToken;
    this.chatId = config.chatId;
    this.minSeverity = config.minSeverity || AlertSeverity.WARNING;
  }

  private shouldSend(severity: AlertSeverity): boolean {
    const levels = [AlertSeverity.INFO, AlertSeverity.WARNING, AlertSeverity.CRITICAL];
    return levels.indexOf(severity) >= levels.indexOf(this.minSeverity);
  }

  private formatMessage(event: AlertEvent): string {
    const icon =
      event.severity === AlertSeverity.CRITICAL
        ? "\u26a0\ufe0f"
        : event.severity === AlertSeverity.WARNING
          ? "\u26a0\ufe0f"
          : "\u2139\ufe0f";

    let msg = `${icon} *${event.severity}*\n`;
    msg += `${event.message}\n`;

    if (event.oracleId) {
      msg += `Oracle: \`${event.oracleId.slice(0, 12)}...\`\n`;
    }
    if (event.market) {
      msg += `Market: ${event.market}\n`;
    }
    if (event.digest) {
      msg += `TX: [${event.digest.slice(0, 12)}...](https://suiscan.xyz/testnet/tx/${event.digest})\n`;
    }

    msg += `\`${event.timestamp}\``;
    return msg;
  }

  async send(event: AlertEvent): Promise<void> {
    if (!this.shouldSend(event.severity)) return;

    try {
      const text = this.formatMessage(event);
      await axios.post(`https://api.telegram.org/bot${this.botToken}/sendMessage`, {
        chat_id: this.chatId,
        text,
        parse_mode: "Markdown",
        disable_web_page_preview: true,
      });
    } catch (e: any) {
      console.error(`[TELEGRAM] Failed to send alert: ${e.message}`);
    }
  }
}

/**
 * Create a configured alert system with both console and Telegram providers
 */
export function createAlertSystem() {
  const { ConsoleAlertProvider, AlertSystem } = require("./alerting.ts");
  const providers: AlertProvider[] = [new ConsoleAlertProvider()];

  const botToken = process.env.TELEGRAM_BOT_TOKEN;
  const chatId = process.env.TELEGRAM_CHAT_ID;

  if (botToken && chatId) {
    providers.push(
      new TelegramAlertProvider({
        botToken,
        chatId,
        minSeverity: AlertSeverity.WARNING,
      }),
    );
    console.log("[ALERT] Telegram alerts enabled");
  } else {
    console.log("[ALERT] Telegram alerts disabled (set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID)");
  }

  return new AlertSystem(providers);
}
