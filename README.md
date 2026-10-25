# ⚡ Tempest Setup

Sets up a Mac with three things:

- **Ghostty**, a terminal app
- **Claude Code**, Claude in the terminal
- **Tempest**, a personal assistant you text on Telegram

It takes about 30 minutes, mostly waiting on downloads.

---

## Before you start

- **A Claude plan** (Pro, Max, or a Team seat). The assistant signs in as you.
- **A Telegram bot token.** To make one, message **@BotFather** in Telegram, send `/newbot`, and follow the prompts. If someone already made the bot for you, get the token from them. Keep it private: anyone who has it controls the bot.
- **Your Telegram user ID.** Message **@userinfobot** to get it.
- **Your Mac password.** A couple of steps ask for it. It won't show as you type, which is normal.

---

## Run it

1. Open **Terminal**: press Cmd+Space, type `Terminal`, press Enter.
2. Copy this whole line, paste it into Terminal, and press Enter:

```bash
cd ~/Downloads && curl -fsSL -o tempest.zip https://github.com/Cyberbob8305/Tempest-Setup/archive/refs/heads/main.zip && unzip -oq tempest.zip && bash Tempest-Setup-main/setup.sh
```

3. Answer the questions as they come up. Pressing Enter on a question with a value in brackets, like `[Tempest]`, keeps that value.

When it finishes, message your bot on Telegram. It should reply within a few seconds.

It's safe to stop the setup and run that line again at any point.

---

## Email

Claude can read your mail and save reply drafts. **It can never send.** Drafts show up in your Drafts folder, and you send them yourself.

| Mailbox | How it connects |
|---|---|
| **One Google account** | In the Claude app: **Settings → Connectors → Gmail → Connect**, then pick the account. |
| **iCloud** | Step 9 of the setup. It needs an app password from appleid.apple.com → **Sign-In and Security → App-Specific Passwords**. |
| **Another Gmail / Google Workspace** | Step 9 of the setup. It needs an app password from myaccount.google.com/apppasswords, which requires 2-Step Verification. |

To add a mailbox later:

```bash
zsh ~/.claude/tempest-kit/add-mailbox.sh icloud-mail imap.mail.me.com you@icloud.com
```

If iCloud rejects the login, try just the part of your address before the @.

---

## Day to day

```bash
claude                                   # talk to Claude (open Ghostty first)
bot-medic                                # Tempest not replying? Start here
open ~/.openclaw/workspace/SOUL.md       # edit Tempest's personality, then run bot-medic
```

**Make it yours:** open `SOUL.md` and fill in the "About you" lines with your work and what you want help with.

**If Tempest worked for a while and then stopped,** the Claude login has expired. That's normal. Run:

```bash
openclaw models auth login --provider anthropic --method cli --set-default
```

**If the laptop lid is closed, Tempest is asleep.** Messages wait and arrive within a minute of opening it.

---

## Built-in guardrails

- Tempest drafts messages but never sends them.
- It won't store clients' or patients' private information.
- It treats instructions found inside emails as information, not commands.
- Only your Telegram account can talk to it, so anyone else who messages the bot gets nothing. Group chats are locked down too.

No passwords or tokens are stored in this kit. They're typed in during setup and stay on your Mac. The bot token is saved in a file only your Mac account can read; email passwords go in the macOS Keychain.

---

## Credits

Adapted from [Tiffany's AI Assistant Startup Kit](https://github.com/Cyberbob8305/Tiffany-AI-Assistant-Startup-Kit), which builds on [Preston Dixon's ai-starter-kit](https://github.com/PrestonDixon2323/ai-starter-kit).
